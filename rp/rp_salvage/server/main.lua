-- rp_salvage / server/main.lua: wiring. The hooks open77_actions calls (exports), the boot order,
-- the library events, the player command and the integrator's lab commands.

local RESOURCE = GetCurrentResourceName()
local cfg, M, L, P = SalvageConfig, SalvageModel, SalvageLedger, SalvagePorts

local Svc = SalvageService.new({ config = cfg, model = M, ledger = L, ports = P, resource = RESOURCE })
-- Inspection handle for the offline suite: a global of this VM only.
SalvageRuntime = { service = Svc }

local function log(line) print("[rp_salvage] " .. line) end

-- ---------------------------------------------------------------------------------------------
-- Hooks. A hook is an export NAME given to open77_actions; any resource can call an export, so
-- each one checks that its caller is open77_actions (and the mutating ones also `verify` the
-- operation). validate is synchronous; the others run asynchronously and may yield.
-- ---------------------------------------------------------------------------------------------
exports("slvValidate", function(ctx) return Svc:validate(ctx) end)
exports("slvReserve", function(ctx) return Svc:reserveWork(ctx) end)
exports("slvCommit", function(ctx) return Svc:commitWork(ctx) end)
exports("slvCancel", function(ctx) return Svc:cancelWork(ctx) end)
exports("slvInspect", function(ctx) return Svc:inspect(ctx) end)
exports("slvDuty", function(ctx) return Svc:duty(ctx) end)
exports("slvUnload", function(ctx) return Svc:unloadAction(ctx) end)
exports("crateValidate", function(ctx) return Svc:crateValidate(ctx) end)
exports("cratePickup", function(ctx) return Svc:cratePickup(ctx) end)
exports("cratePutdown", function(ctx) return Svc:cratePutdown(ctx) end)
exports("crateDropped", function(ctx) return Svc:crateDropped(ctx) end)

-- ---------------------------------------------------------------------------------------------
-- Boot: the coordinator ready, then items, nodes, actions, crates. Nothing is accepted before.
-- ---------------------------------------------------------------------------------------------
local function waitFor(what, test, seconds)
    local waited, warned = 0, false
    while not test() do
        Wait(500)
        waited = waited + 0.5
        if waited >= (seconds or 30) and not warned then
            warned = true
            log(("still waiting for %s (the pilot accepts nothing until then)"):format(what))
        end
    end
end

local function boot()
    waitFor("open77_transactions (ready)", function() return (L.ready()) end)
    waitFor("open77_actions", function() return P.running("open77_actions") end)
    waitFor("open77_containers", function() return P.running("open77_containers") end)
    local info = L.info()
    log(("coordinator ready (store=%s)"):format(tostring(info and info.store)))
    if info and info.store ~= "sql" then
        log("WARNING: the coordinator runs the DISPOSABLE lab store: nothing here survives a lab reset")
    end
    if P.running("rp_inventory") then
        local backend = P.inventory.backend()
        if backend ~= "transactions" then
            log(("WARNING: rp_inventory backend is %s; tools in pockets are invisible to the coordinator until " ..
                "rp_inventory_backend is transactions"):format(tostring(backend)))
        end
    end
    Svc:defineItems()
    -- open77_containers answers `not_ready` until its boot join is done (it waits for the
    -- coordinator too). Wait for it: the create of each keyed node is the probe, as its
    -- `open77_containers:ready` is missed when it was up first. A lasting refusal (a missing
    -- `writers` entry, a node closed by an operator) is logged and retried by the sweep instead.
    waitFor("open77_containers (ready)", function()
        local done, why = Svc:loadNodes()
        return done or not Svc:nodesTransient(why)
    end)
    local missing = 0
    for _, node in pairs(Svc.nodes) do if not node.id then missing = missing + 1 end end
    if missing > 0 then
        log(("WARNING: %d of %d wreck nodes unavailable (reasons above); asked for again every 30 s")
            :format(missing, #cfg.nodes))
    end
    Svc:declare()
    Svc:loadCrates()
    Svc:spawnBuyer()
    Svc.ready = true
    local nodes = missing == 0 and tostring(#cfg.nodes) or ("%d of %d"):format(#cfg.nodes - missing, #cfg.nodes)
    log(("ready: %s wreck nodes, foreman, loading bay, unloading bay, buyer counter (job %s)"):format(nodes, cfg.job))
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
-- open77_actions restarted: it forgot every definition, target, item and carry.
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

-- open77_containers finished a boot join (first start, or after a restart): its node ids are
-- durable (keyed), so this finds the same ones again; then the prompts and any charge kept back.
AddEventHandler("open77_containers:ready", function()
    Svc.containersUp = true
    if not Svc.ready then return end    -- the boot is still loading the nodes itself
    CreateThread(function()
        local done, why = Svc:loadNodes()
        if not done then log(("open77_containers is back, nodes not all found yet (%s)"):format(tostring(why))) end
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
    print("[rp_salvage] " .. message)
    local pid = M.playerId(source)
    if pid then pcall(Open77.chat.send, pid, { author = "Scrapyard", text = message }) end
end

local function argPlayer(source, value)
    local pid = M.playerId(value)
    if not pid or not P.players.name(pid) then
        reply(source, "unknown player id " .. tostring(value))
        return nil
    end
    return pid
end

-- Player: /salvage [load | unload | crates]
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
    local allowed, why = P.jobs.eligible(pid, cfg.eligibility.args)
    if not allowed then return Svc:refuseTo(pid, why) end
    local crate, itemOrWhy = Svc:unloadCrate(pid, nil, P.players.position(pid), cfg.truckNearM, nil)
    if not crate then return Svc:refuseTo(pid, itemOrWhy) end
    local op, reason = P.actions.carryPickup(pid, itemOrWhy)
    if not op then Svc:refuseTo(pid, reason) end
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

RegisterCommand("salvage", function(source, args)
    local pid = M.playerId(source)
    if not pid then return print("[rp_salvage] /salvage is a player command; the console uses salvage.lab.*") end
    local verb = args and args[1] or ""
    if not Svc.ready then return Svc:tell(pid, M.textFor("salvage_unavailable"), "warning") end
    if verb == "load" then
        CreateThread(function() playerLoad(pid) end)
    elseif verb == "unload" then
        CreateThread(function() playerUnload(pid) end)
    elseif verb == "crates" then
        local subject = L.subjectOf(pid)
        local list = subject and describeCrates(subject) or {}
        Svc:tell(pid, #list > 0 and ("Your crates: " .. table.concat(list, "; ")) or "You have no crate out.", "info")
    else
        Svc:tell(pid, "Scrapyard: clock in with the foreman, cut or pry a wreck (E), carry the crate (E / G), " ..
            "load it at the bay or /salvage load next to your truck, /salvage unload at the buyer, sell it at the counter.", "info")
    end
end, false)

-- Operator / integrator (restricted: console, or ACL command.salvage.*)
RegisterCommand("salvage.status", function(source)
    local n = { ground = 0, carried = 0, truck = 0, new = 0, sold = 0, other = 0 }
    for _, crate in pairs(Svc.crates) do
        local key = n[crate.state] and crate.state or "other"
        n[key] = n[key] + 1
    end
    local doubts = 0
    for _ in pairs(Svc.doubts) do doubts = doubts + 1 end
    local s = Svc.stats
    reply(source, ("ready=%s crates: ground=%d carried=%d truck=%d new=%d sold=%d other=%d | works=%d loads=%d " ..
        "unloads=%d sales=%d retired=%d refusals=%d doubts=%d (open %d)"):format(tostring(Svc.ready), n.ground,
        n.carried, n.truck, n.new, n.sold, n.other, s.works, s.loads, s.unloads, s.sales, s.retired, s.refusals,
        s.doubts, doubts))
    for key, node in pairs(Svc.nodes) do
        local summary = node.id and P.containers.summary(node.id)
        reply(source, ("node %s id=%s charges=%s/%s depleted=%s"):format(key, tostring(node.id),
            tostring(summary and summary.charges), tostring(summary and summary.maxCharges), tostring(node.depleted)))
    end
end, true)

-- salvage.lab.setup <playerId> [crowbar|welder|both]: job + duty + tool instance(s).
RegisterCommand("salvage.lab.setup", function(source, args)
    local pid = argPlayer(source, args[1])
    if not pid then return end
    local which = args[2] or "both"
    CreateThread(function()
        local ok, why = P.jobs.setJob(pid, cfg.job, 0)
        reply(source, ("setJob %d %s: %s %s"):format(pid, cfg.job, tostring(ok), tostring(why or "")))
        local on, dwhy = P.jobs.setDuty(pid, true, { job = cfg.job })
        reply(source, ("setDuty %d on: %s %s"):format(pid, tostring(on), tostring(dwhy or "")))
        for _, tool in ipairs(which == "both" and { "crowbar", "welder" } or { which }) do
            local receipt, twhy = P.inventory.addAsync(pid, tool, 1, nil, { opId = L.newOpId("labtool") })
            reply(source, ("give %s to %d: %s %s"):format(tool, pid, receipt and "ok" or "refused", tostring(twhy or "")))
        end
    end)
end, true)

-- salvage.lab.clock <playerId> on|off
RegisterCommand("salvage.lab.clock", function(source, args)
    local pid = argPlayer(source, args[1])
    if not pid then return end
    local ok, why = P.jobs.setDuty(pid, args[2] ~= "off", { job = cfg.job })
    reply(source, ("duty %d %s: %s %s"):format(pid, args[2] or "on", tostring(ok), tostring(why or "")))
end, true)

-- salvage.lab.truck <playerId> [plate]: a plated, owned Mackinaw next to the player.
RegisterCommand("salvage.lab.truck", function(source, args)
    local pid = argPlayer(source, args[1])
    if not pid then return end
    if args[2] then
        local id, why = P.garage.spawnOwned(pid, args[2])
        reply(source, id and ("plate %s out as vehicle %s next to player %d"):format(args[2], tostring(id), pid)
            or ("spawnOwned refused: %s"):format(tostring(why)))
        return
    end
    local res, why = P.garage.labIssue(pid, "Vehicle.v_standard3_thorton_mackinaw_player", { label = "Yard truck" })
    if type(res) == "table" then
        reply(source, ("issued plate %s vehicle %s to player %d"):format(tostring(res.plate), tostring(res.vehicleId), pid))
        return
    end
    local manual = ("Give the player the money (/givemoney %d 30000), buy a Thorton Mackinaw at the dealership, " ..
        "then: salvage.lab.truck %d <plate>"):format(pid, pid)
    if why == "lab_disabled" then
        reply(source, "rp_garage refuses labIssue without the convar rp_garage_lab 1 (lab servers only). " .. manual)
    elseif why == "rp_garage_unavailable" then
        reply(source, ("rp_garage has no lab issue export yet (%s). "):format(tostring(why)) .. manual)
    else
        reply(source, ("labIssue refused: %s. "):format(tostring(why)) .. manual)
    end
end, true)

-- salvage.lab.work <playerId> <node> [cut|pry|inspect]: the same request a prompt makes.
RegisterCommand("salvage.lab.work", function(source, args)
    local pid = argPlayer(source, args[1])
    if not pid then return end
    local key, action = args[2], args[3] or "cut"
    if not Svc.nodes[key or ""] then return reply(source, "unknown node " .. tostring(key)) end
    local op, why, info = P.actions.request(pid, action, "node_" .. key)
    reply(source, op and ("work %s on %s: op %s state %s"):format(action, key, tostring(op.opId), tostring(op.state))
        or ("work refused: %s (stage %s)"):format(tostring(why), tostring(info and info.stage)))
end, true)

-- salvage.lab.pickup <playerId> [crateKey]: the nearest ground crate within 3 m, or that one.
RegisterCommand("salvage.lab.pickup", function(source, args)
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

-- salvage.lab.load <playerId> [vehicleId]
RegisterCommand("salvage.lab.load", function(source, args)
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

-- salvage.lab.unload <playerId> [vehicleId]
RegisterCommand("salvage.lab.unload", function(source, args)
    local pid = argPlayer(source, args[1])
    if not pid then return end
    CreateThread(function()
        local crate, itemOrWhy = Svc:unloadCrate(pid, M.playerId(args[2]), P.players.position(pid), cfg.truckNearM, nil)
        if not crate then return reply(source, "unload refused: " .. tostring(itemOrWhy)) end
        local op, why = P.actions.carryPickup(pid, itemOrWhy)
        reply(source, ("unloaded %s; pickup %s"):format(crate.key, op and ("op " .. tostring(op.opId)) or ("refused: " .. tostring(why))))
    end)
end, true)

-- salvage.lab.sell <playerId>: put the carried crate down on the counter (stand at the counter).
RegisterCommand("salvage.lab.sell", function(source, args)
    local pid = argPlayer(source, args[1])
    if not pid then return end
    local op, why = P.actions.carryPutdown(pid, { kind = "point", position = cfg.buyer.counter, yaw = cfg.buyer.yaw },
        { data = { intent = "sell" } })
    reply(source, op and ("sale put-down: op %s"):format(tostring(op.opId)) or ("sale refused: " .. tostring(why)))
end, true)

-- salvage.lab.drop <playerId>: force a drop (as a death would).
RegisterCommand("salvage.lab.drop", function(source, args)
    local pid = argPlayer(source, args[1])
    if not pid then return end
    local ok, why = P.actions.carryDrop(pid, "lab_drop")
    reply(source, ok and "dropped" or ("drop refused: " .. tostring(why)))
end, true)

-- salvage.lab.reset [node|all]: wreck nodes back to full charges, in place (same node id).
RegisterCommand("salvage.lab.reset", function(source, args)
    local which = args[1] or "all"
    CreateThread(function()
        for key, node in pairs(Svc.nodes) do
            if which == "all" or which == key then
                local state, why = Svc:resetNode(key)
                reply(source, ("node %s: %s"):format(key, state and ("refilled %s to %s/%s"):format(tostring(node.id),
                    tostring(state.charges), tostring(state.maxCharges)) or ("reset refused: " .. tostring(why))))
            end
        end
    end)
end, true)

-- salvage.lab.state <playerId>: crates (where, contents), tools (durability), cash, receipts.
RegisterCommand("salvage.lab.state", function(source, args)
    local pid = argPlayer(source, args[1])
    if not pid then return end
    CreateThread(function()
        local subject, why = L.subjectOf(pid)
        if not subject then return reply(source, "no subject: " .. tostring(why)) end
        reply(source, ("player %d subject %s"):format(pid, subject))
        for _, crate in ipairs(Svc:cratesOf(subject)) do
            local snap = L.read(crate.id)
            local items = {}
            for item, count in pairs(type(snap) == "table" and snap.items or {}) do items[#items + 1] = item .. "=" .. count end
            table.sort(items)
            reply(source, ("crate %s state=%s token=%s at=%s plate=%s contents={%s} weightG=%s sale=%s"):format(
                crate.id, crate.state, tostring(M.tokenHere(snap, crate.iid) and "hold" or "away"),
                crate.meta.at and ("%.1f,%.1f,%.1f"):format(crate.meta.at.x, crate.meta.at.y, crate.meta.at.z) or "-",
                tostring(crate.plate or crate.meta.where or "-"), table.concat(items, ","),
                tostring(snap and snap.weightG), tostring(crate.meta.sale and crate.meta.sale.opId or "-")))
        end
        local pockets = L.read("char:" .. subject)
        for iid, inst in pairs(type(pockets) == "table" and pockets.instances or {}) do
            if cfg.tools[inst.item] then
                reply(source, ("tool %s %s durability=%s"):format(inst.item, iid, tostring(M.durabilityOf(inst, cfg.tools[inst.item]))))
            end
        end
        local cash = P.economy.balanceOf({ subject = subject })
        local soc = P.economy.balanceOf({ society = cfg.society })
        reply(source, ("cash=%s society %s=%s"):format(tostring(type(cash) == "table" and cash.balance),
            cfg.society, tostring(type(soc) == "table" and soc.balance)))
        for _, entry in ipairs(Svc.receipts[subject] or {}) do
            reply(source, ("receipt %s %s%s: %s"):format(entry.kind, entry.opId, entry.replay and " (replay)" or "", entry.text or ""))
        end
    end)
end, true)
