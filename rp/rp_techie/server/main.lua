-- rp_techie / server/main.lua: wiring. The hooks open77_actions calls (exports), the boot order,
-- the library and platform events, the exports other jobs use (the ripperdoc buys cyberware
-- components), the player command and the integrator's lab commands.

local RESOURCE = GetCurrentResourceName()
local cfg, M, L, P = TechieConfig, TechieModel, TechieLedger, TechiePorts

local Svc = TechieService.new({ config = cfg, model = M, ledger = L, ports = P, resource = RESOURCE })
-- Inspection handle for the offline suite: a global of this VM only.
TechieRuntime = { service = Svc }

local function log(line) print("[rp_techie] " .. line) end

-- ---------------------------------------------------------------------------------------------
-- Hooks. A hook is an export NAME given to open77_actions; any resource can call an export, so
-- each one checks that its caller is open77_actions (and the mutating ones also `verify` the
-- operation). validate is synchronous; the others run asynchronously and may yield.
-- ---------------------------------------------------------------------------------------------
exports("tchValidate", function(ctx) return Svc:validate(ctx) end)
exports("tchReserve", function(ctx) return Svc:reserve(ctx) end)
exports("tchCommit", function(ctx) return Svc:commit(ctx) end)
exports("tchCancel", function(ctx) return Svc:cancelHook(ctx) end)

-- ---------------------------------------------------------------------------------------------
-- Exports for other jobs. Synchronous reads never yield; `offer` reads the seller's pockets, so
-- call it with Open77.exports.call(...):await() from a thread.
-- ---------------------------------------------------------------------------------------------
-- The cyberware components the ripperdoc job buys: { { id, label, category, weightG, shopPrice,
-- suggestedPrice } }, in a stable order.
exports("components", function() return Svc:listInfo(cfg.cyberwareComponents) end)
exports("products", function() return Svc:listInfo(cfg.products) end)
exports("catalogue", function() return Svc:catalogue() end)
exports("isComponent", function(item) return M.contains(cfg.cyberwareComponents, item) end)

-- offer({ seller, buyer, item, count?, price?, initiator = "seller" | "buyer" }) ->
-- { interaction, sale } | nil, reason. Starts a consented trade between two connected players
-- (the responder accepts with Y on the offer card, or /interaction accept). Callers: cfg.trade.offerCallers.
exports("offer", function(spec)
    local caller = GetInvokingResource()
    if not caller or not cfg.trade.offerCallers[caller] then return nil, "caller_not_allowed" end
    if not Svc.ready then return nil, "techie_unavailable" end
    if type(spec) ~= "table" then return nil, "invalid_spec" end
    local o, why = Svc:startTrade({ seller = spec.seller, buyer = spec.buyer, item = spec.item, count = spec.count,
        price = spec.price, initiator = spec.initiator, via = "export:" .. caller })
    if not o then return nil, why end
    return { interaction = o.id, sale = o.opId, price = o.price, count = o.count }
end)

-- ---------------------------------------------------------------------------------------------
-- Boot: coordinator ready, then items, workshop trays, actions and targets.
-- ---------------------------------------------------------------------------------------------
local function waitFor(what, test, seconds)
    local waited, warned = 0, false
    while not test() do
        Wait(500)
        waited = waited + 0.5
        if waited >= (seconds or 30) and not warned then
            warned = true
            log(("still waiting for %s (the workshop accepts nothing until then)"):format(what))
        end
    end
end

-- rp_salvage owns scrap_metal and copper_wire: give it time to define them, then define here
-- whatever is still unknown (a server without rp_salvage).
local function ensureParts()
    local deadline = cfg.partsDefineWaitS or 20
    local waited = 0
    while P.running("rp_salvage") and waited < deadline do
        local all = true
        for item in pairs(cfg.partDefinitions) do
            if type(P.inventory.itemDefinition(item)) ~= "table" then all = false end
        end
        if all then return end
        Wait(1000)
        waited = waited + 1
    end
    Svc:defineParts()
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
            "rp_inventory_backend is transactions (every stage and sale refuses)"):format(tostring(backend)))
    end
    for _ = 1, 60 do
        if Svc:defineItems() then break end
        Wait(1000)
    end
    ensureParts()
    local enabled = Svc:enabledWorkshops()
    for _ = 1, 60 do
        if Svc:openWorkshops() >= enabled then break end
        Wait(1000)
    end
    local targets = Svc:declare()
    Svc.ready = true
    local names = {}
    for key, ws in pairs(Svc.workshops) do if ws.opened then names[#names + 1] = key end end
    table.sort(names)
    log(("ready: workshops %s, %d targets, shop payment %s (job %s)"):format(table.concat(names, ","), targets,
        cfg.shopPayment, cfg.job))
    -- The job must exist in rp_jobs, or every action is refused unknown_job.
    local _, why = P.jobs.eligible(-1, { job = cfg.job })
    if why == "unknown_job" then
        log(("WARNING: rp_jobs does not know the job '%s': add it to rp_jobs, or set the convar rp_techie_job"):format(cfg.job))
    end
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

-- Consented trades (delivered to the owning resource by the platform).
AddEventHandler("onPlayerInteractionCompleted", function(state)
    CreateThread(function() Svc:onInteractionCompleted(state) end)
end)
AddEventHandler("onPlayerInteractionCancelled", function(state)
    CreateThread(function() Svc:onInteractionCancelled(state) end)
end)

-- The techie's shift moved: withdraw a pending offer at once.
AddEventHandler("rp_jobs:workEpoch", function(playerId, epoch)
    Svc:onWorkEpoch(playerId, epoch)
end)

AddEventHandler("onPlayerDisconnected", function(playerId)
    Svc:onDisconnected(playerId)
end)

AddEventHandler("onResourceStart", function(name)
    if name == "rp_inventory" and Svc.ready then
        CreateThread(function()
            Svc:defineItems()
            ensureParts()
        end)
    end
end)

AddEventHandler("onResourceStop", function(name)
    if name == RESOURCE then Svc:shutdown() end
end)

-- ---------------------------------------------------------------------------------------------
-- Commands
-- ---------------------------------------------------------------------------------------------
local function reply(source, message)
    print("[rp_techie] " .. message)
    local pid = M.playerId(source)
    if pid then pcall(Open77.chat.send, pid, { author = "Techie", text = message }) end
end

local function argPlayer(source, value)
    local pid = M.playerId(value)
    if not pid or not P.players.name(pid) then
        reply(source, "unknown player id " .. tostring(value))
        return nil
    end
    return pid
end

local function describeCounts(snap)
    local parts = {}
    for item, n in pairs(type(snap) == "table" and snap.items or {}) do parts[#parts + 1] = item .. "=" .. n end
    table.sort(parts)
    return table.concat(parts, ",")
end

local function requestFor(pid, action, target, options)
    local op, why, info = P.actions.request(pid, action, target, options)
    if not op then Svc:refuseTo(pid, why) end
    return op, why, info
end

local function benchFor(pid, recipeKey, radius)
    local r = cfg.recipes[recipeKey]
    return r and Svc:nearestBench(pid, r.bench, radius) or nil
end

local function tradeFromCommand(pid, initiator, args)
    local other = M.playerId(args[2])
    local item = args[3]
    local count = args[4] and tonumber(args[4]) or 1
    local price = args[5] and tonumber(args[5]) or nil
    local spec = { item = item, count = count, price = price, initiator = initiator, via = "command" }
    if initiator == "seller" then spec.seller, spec.buyer = pid, other else spec.seller, spec.buyer = other, pid end
    local o, why = Svc:startTrade(spec)
    if not o then Svc:refuseTo(pid, why) end
end

-- Player: /techie [recipes | craft <recipe> | tray | prices | sell <id> <item> [count] [price]
--                  | buy <id> <item> [count] [price] | cancel]
RegisterCommand("techie", function(source, args)
    local pid = M.playerId(source)
    if not pid then return print("[rp_techie] /techie is a player command; the console uses techie.lab.*") end
    if not Svc.ready then return Svc:tell(pid, M.textFor("techie_unavailable"), "warning") end
    local verb = args and args[1] or ""
    CreateThread(function()
        local labelOf = function(i) return Svc:labelOf(i) end
        if verb == "recipes" then
            local parts = {}
            for _, key in ipairs(cfg.recipeOrder) do
                local r = cfg.recipes[key]
                parts[#parts + 1] = ("%s [%s, %s%s]: %s"):format(key, r.stage, cfg.benchTypes[r.bench].label,
                    (r.minGrade or 0) > 0 and (", grade " .. r.minGrade) or "", M.recipeText(r, labelOf))
            end
            Svc:tell(pid, "Recipes: " .. table.concat(parts, "; "), "info")
        elseif verb == "craft" then
            local key = args[2]
            if not cfg.recipes[key or ""] then return Svc:refuseTo(pid, "unknown_recipe") end
            local bench = benchFor(pid, key, cfg.maxDistance)
            if not bench then return Svc:refuseTo(pid, "no_bench_near") end
            requestFor(pid, "craft_" .. key, bench.targetId)
        elseif verb == "tray" then
            local ws = Svc:nearestWorkshop(pid, 15.0)
            if not ws then return Svc:refuseTo(pid, "no_bench_near") end
            local snap = L.read(ws.tray)
            Svc:tell(pid, ("%s tray: %s."):format(ws.cfg.label, Svc:trayText(ws, type(snap) == "table" and snap or nil)), "info")
        elseif verb == "prices" then
            local parts = {}
            for _, item in ipairs(cfg.products) do
                local p = cfg.prices[item] or {}
                parts[#parts + 1] = ("%s: shop %s, suggested %s"):format(labelOf(item), M.money(p.shop), M.money(p.suggested))
            end
            for _, item in ipairs(cfg.parts) do
                parts[#parts + 1] = ("%s: suggested %s"):format(labelOf(item), M.money((cfg.prices[item] or {}).suggested))
            end
            Svc:tell(pid, "Prices per unit: " .. table.concat(parts, "; "), "info")
        elseif verb == "sell" then
            tradeFromCommand(pid, "seller", args)
        elseif verb == "buy" then
            tradeFromCommand(pid, "buyer", args)
        elseif verb == "cancel" then
            local ok, why = Svc:withdraw(pid)
            if not ok then Svc:refuseTo(pid, why) end
        else
            Svc:tell(pid, "Techie: clock in (/service), buy parts from the dealer (E) or from a scrapper " ..
                "(/techie buy <id> <item> [count] [price]), strip them at a workbench (E), assemble on the tray " ..
                "(E), sell to the gun shop or Med-Point (E) or to a player (/techie sell <id> <item> [count] [price]). " ..
                "Also /techie recipes, /techie craft <recipe>, /techie tray, /techie prices, /techie cancel.", "info")
        end
    end)
end, false)

-- Operator / integrator (restricted: console, or ACL command.techie.*)
RegisterCommand("techie.status", function(source)
    local s = Svc.stats
    local offers, doubts, sales = 0, 0, 0
    for _ in pairs(Svc.offers) do offers = offers + 1 end
    for _ in pairs(Svc.doubts) do doubts = doubts + 1 end
    for _ in pairs(Svc.sales) do sales = sales + 1 end
    reply(source, ("ready=%s targets=%s shopPayment=%s | strips=%d assembles=%d buys=%d shopSales=%d trades=%d " ..
        "menus=%d declined=%d dropped=%d refusals=%d doubts=%d | open offers=%d stage doubts=%d sale doubts=%d")
        :format(tostring(Svc.ready), tostring(Svc.targetCount), cfg.shopPayment, s.strips, s.assembles, s.buys,
        s.shopSales, s.trades, s.menus, s.declined, s.dropped, s.refusals, s.doubts, offers, doubts, sales))
end, true)

-- techie.mintrules [first slot]: the coordinator mint rules this configuration needs, one
-- `tunable.set` line per slot (a tunable holds 256 characters), numbered from `first slot`
-- (default 3): pick slots no other job uses.
RegisterCommand("techie.mintrules", function(source, args)
    local first = math.tointeger(tonumber(args and args[1] or "")) or 3
    local slots = M.mintSlots(M.mintRules(cfg, RESOURCE))
    if first < 1 or first + #slots - 1 > 6 then
        return reply(source, ("%d slot(s) needed: give a first slot from 1 to %d"):format(#slots, 7 - #slots))
    end
    for i, value in ipairs(slots) do
        reply(source, ("tunable.set open77_transactions mint%d %s"):format(first + i - 1, value))
    end
end, true)

-- techie.lab.setup <playerId> [grade]: the techie job at that grade + duty.
RegisterCommand("techie.lab.setup", function(source, args)
    local pid = argPlayer(source, args[1])
    if not pid then return end
    local grade = math.tointeger(tonumber(args[2] or "0")) or 0
    local ok, why = P.jobs.setJob(pid, cfg.job, grade)
    reply(source, ("setJob %d %s %d: %s %s"):format(pid, cfg.job, grade, tostring(ok), tostring(why or "")))
    local on, dwhy = P.jobs.setDuty(pid, true, { job = cfg.job })
    reply(source, ("setDuty %d on: %s %s"):format(pid, tostring(on), tostring(dwhy or "")))
end, true)

-- techie.lab.clock <playerId> on|off
RegisterCommand("techie.lab.clock", function(source, args)
    local pid = argPlayer(source, args[1])
    if not pid then return end
    local ok, why = P.jobs.setDuty(pid, args[2] ~= "off", { job = cfg.job })
    reply(source, ("duty %d %s: %s %s"):format(pid, args[2] or "on", tostring(ok), tostring(why or "")))
end, true)

-- techie.lab.give <playerId> <item> <count>: items into a player's pockets (rp_inventory addAsync).
RegisterCommand("techie.lab.give", function(source, args)
    local pid = argPlayer(source, args[1])
    if not pid then return end
    local item, n = args[2], math.tointeger(tonumber(args[3] or "1")) or 1
    if not cfg.items[item or ""] and not M.contains(cfg.parts, item) then return reply(source, "unknown item " .. tostring(item)) end
    CreateThread(function()
        local receipt, why = P.inventory.addAsync(pid, item, n, nil, { opId = L.newOpId("labgive") })
        reply(source, ("give %d %s to %d: %s %s"):format(n, item, pid, receipt and "ok" or "refused", tostring(why or "")))
    end)
end, true)

-- techie.lab.craft <playerId> <recipe> [workshop]: the same request the bench prompt makes.
RegisterCommand("techie.lab.craft", function(source, args)
    local pid = argPlayer(source, args[1])
    if not pid then return end
    local key = args[2]
    local r = cfg.recipes[key or ""]
    if not r then return reply(source, "unknown recipe " .. tostring(key)) end
    local wsKey = args[3] or cfg.workshopOrder[1]
    local target
    for id, bench in pairs(Svc.benches) do
        if bench.workshop == wsKey and bench.type == r.bench then target = id end
    end
    if not target then return reply(source, ("no %s bench in workshop %s"):format(r.bench, tostring(wsKey))) end
    local op, why, info = P.actions.request(pid, "craft_" .. key, target)
    reply(source, op and ("craft %s at %s: op %s state %s"):format(key, target, tostring(op.opId), tostring(op.state))
        or ("craft refused: %s (stage %s)"):format(tostring(why), tostring(info and info.stage)))
end, true)

-- techie.lab.buy <playerId> <item> [dealer]: the dealer prompt's request.
RegisterCommand("techie.lab.buy", function(source, args)
    local pid = argPlayer(source, args[1])
    if not pid then return end
    local dealerKey = args[3] or cfg.dealerOrder[1]
    local dealer = Svc.dealers[dealerKey]
    if not dealer then return reply(source, "unknown dealer " .. tostring(dealerKey)) end
    local op, why, info = P.actions.request(pid, ("buy_%s_%s"):format(dealerKey, tostring(args[2])), dealer.targetId)
    reply(source, op and ("buy %s: op %s"):format(tostring(args[2]), tostring(op.opId))
        or ("buy refused: %s (stage %s)"):format(tostring(why), tostring(info and info.stage)))
end, true)

-- techie.lab.shop <playerId> <shop>: the shop prompt's request.
RegisterCommand("techie.lab.shop", function(source, args)
    local pid = argPlayer(source, args[1])
    if not pid then return end
    local shop = Svc.shops[args[2] or ""]
    if not shop then return reply(source, "unknown shop " .. tostring(args[2])) end
    local op, why, info = P.actions.request(pid, "sell_" .. shop.key, shop.targetId)
    reply(source, op and ("sell to %s: op %s"):format(shop.key, tostring(op.opId))
        or ("sell refused: %s (stage %s)"):format(tostring(why), tostring(info and info.stage)))
end, true)

-- techie.lab.offer <sellerId> <buyerId> <item> [count] [price] [seller|buyer]: a consented trade
-- (the responder accepts with Y on the offer card, or /interaction accept). The last word says who
-- asked (default seller).
RegisterCommand("techie.lab.offer", function(source, args)
    local seller = argPlayer(source, args[1])
    local buyer = seller and argPlayer(source, args[2])
    if not buyer then return end
    CreateThread(function()
        local o, why = Svc:startTrade({ seller = seller, buyer = buyer, item = args[3], count = tonumber(args[4] or "1"),
            price = args[5] and tonumber(args[5]) or nil, initiator = args[6] == "buyer" and "buyer" or "seller", via = "lab" })
        reply(source, o and ("trade %s: %d -> %d, %d %s for %d, sale %s; the responder accepts with Y on the offer card, or /interaction accept")
            :format(o.id, seller, buyer, o.count, o.item, o.price, o.opId) or ("trade refused: " .. tostring(why)))
    end)
end, true)

-- techie.lab.state <playerId>: techie items in the pockets, cash, offer, receipts.
RegisterCommand("techie.lab.state", function(source, args)
    local pid = argPlayer(source, args[1])
    if not pid then return end
    CreateThread(function()
        local subject, why = L.subjectOf(pid)
        if not subject then return reply(source, "no subject: " .. tostring(why)) end
        local pockets = L.read("char:" .. subject)
        local parts = {}
        for item, n in pairs(type(pockets) == "table" and pockets.items or {}) do
            if cfg.items[item] or M.contains(cfg.parts, item) then parts[#parts + 1] = item .. "=" .. n end
        end
        table.sort(parts)
        local cash = P.economy.balanceOf({ subject = subject })
        local soc = P.economy.balanceOf({ society = cfg.society })
        reply(source, ("player %d subject %s pockets={%s} cash=%s society %s=%s offer=%s"):format(pid, subject,
            table.concat(parts, ","), tostring(type(cash) == "table" and cash.balance), cfg.society,
            tostring(type(soc) == "table" and soc.balance), tostring(Svc.offerOf[pid] or "-")))
        for _, entry in ipairs(Svc.receipts[subject] or {}) do
            reply(source, ("receipt %s %s%s: %s"):format(entry.kind, entry.opId, entry.replay and " (replay)" or "", entry.text or ""))
        end
    end)
end, true)

-- techie.lab.tray [workshop]: the tray's contents (the work in progress between stages).
RegisterCommand("techie.lab.tray", function(source, args)
    local ws = Svc.workshops[args[1] or cfg.workshopOrder[1]]
    if not ws or not ws.opened then return reply(source, "unknown or closed workshop " .. tostring(args[1])) end
    CreateThread(function()
        local snap = L.read(ws.tray)
        reply(source, ("workshop %s tray %s {%s} weightG=%s/%s"):format(ws.key, ws.tray, describeCounts(snap),
            tostring(type(snap) == "table" and snap.weightG), tostring(type(snap) == "table" and snap.capacityG)))
        for id, bench in pairs(Svc.benches) do
            if bench.workshop == ws.key then
                reply(source, ("bench %s %s (%s) at %.3f,%.3f,%.3f yaw %.2f"):format(id, bench.label, bench.type,
                    bench.position.x, bench.position.y, bench.position.z, bench.yaw or 0))
            end
        end
    end)
end, true)
