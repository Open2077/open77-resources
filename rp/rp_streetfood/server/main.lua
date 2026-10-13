-- rp_streetfood / server/main.lua: wiring. The hooks open77_actions calls (exports), the boot order,
-- the library and platform events, the player command and the integrator's lab commands.

local RESOURCE = GetCurrentResourceName()
local cfg, M, L, P = StreetfoodConfig, StreetfoodModel, StreetfoodLedger, StreetfoodPorts

local Svc = StreetfoodService.new({ config = cfg, model = M, ledger = L, ports = P, resource = RESOURCE })
-- Inspection handle for the offline suite: a global of this VM only.
StreetfoodRuntime = { service = Svc }

local function log(line) print("[rp_streetfood] " .. line) end

-- ---------------------------------------------------------------------------------------------
-- Hooks. A hook is an export NAME given to open77_actions; any resource can call an export, so
-- each one checks that its caller is open77_actions (and the mutating ones also `verify` the
-- operation). validate is synchronous; the others run asynchronously and may yield.
-- ---------------------------------------------------------------------------------------------
exports("sfValidate", function(ctx) return Svc:validate(ctx) end)
exports("sfReserve", function(ctx) return Svc:reserve(ctx) end)
exports("sfCommit", function(ctx) return Svc:commit(ctx) end)
exports("sfCancel", function(ctx) return Svc:cancelHook(ctx) end)

-- ---------------------------------------------------------------------------------------------
-- Boot: coordinator ready, then items, stall containers, actions and targets.
-- ---------------------------------------------------------------------------------------------
local function waitFor(what, test, seconds)
    local waited, warned = 0, false
    while not test() do
        Wait(500)
        waited = waited + 0.5
        if waited >= (seconds or 30) and not warned then
            warned = true
            log(("still waiting for %s (the stall accepts nothing until then)"):format(what))
        end
    end
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
            "rp_inventory_backend is transactions (meals and stocking refuse)"):format(tostring(backend)))
    end
    for _ = 1, 60 do
        if Svc:defineItems() then break end
        Wait(1000)
    end
    local enabled = 0
    for _, key in ipairs(cfg.stallOrder) do if cfg.stalls[key] and cfg.stalls[key].enabled then enabled = enabled + 1 end end
    for _ = 1, 60 do
        if Svc:openStalls() >= enabled then break end
        Wait(1000)
    end
    local targets = Svc:declare()
    Svc.ready = true
    local names = {}
    for key, stall in pairs(Svc.stalls) do if stall.opened then names[#names + 1] = key end end
    table.sort(names)
    log(("ready: stalls %s, %d targets, seating %s (job %s)"):format(table.concat(names, ","), targets,
        cfg.seating.enabled and "on" or "off", cfg.job))
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

-- The hand-over (delivered to the owning resource by the platform).
AddEventHandler("onPlayerInteractionCompleted", function(state)
    CreateThread(function() Svc:onInteractionCompleted(state) end)
end)
AddEventHandler("onPlayerInteractionCancelled", function(state)
    CreateThread(function() Svc:onInteractionCancelled(state) end)
end)

-- The cook's shift moved: withdraw a pending offer at once.
AddEventHandler("rp_jobs:workEpoch", function(playerId, epoch)
    Svc:onWorkEpoch(playerId, epoch)
end)

AddEventHandler("onPlayerDisconnected", function(playerId)
    Svc:onDisconnected(playerId)
end)

AddEventHandler("onResourceStart", function(name)
    if name == "rp_inventory" and Svc.ready then
        CreateThread(function() Svc:defineItems() end)
    end
end)

AddEventHandler("onResourceStop", function(name)
    if name == RESOURCE then Svc:shutdown() end
end)

-- ---------------------------------------------------------------------------------------------
-- Commands
-- ---------------------------------------------------------------------------------------------
local function reply(source, message)
    print("[rp_streetfood] " .. message)
    local pid = M.playerId(source)
    if pid then pcall(Open77.chat.send, pid, { author = "Street food", text = message }) end
end

local function argPlayer(source, value)
    local pid = M.playerId(value)
    if not pid or not P.players.name(pid) then
        reply(source, "unknown player id " .. tostring(value))
        return nil
    end
    return pid
end

-- The enabled stall whose `role` point (grill | counter) is nearest to the player, within `radius`.
local function nearestStall(pid, role, radius)
    local pos = P.players.position(pid)
    local best, bestD
    for key, stall in pairs(Svc.stalls) do
        if stall.opened then
            local d = M.distance(pos, stall.cfg[role].position)
            if d and d <= radius and (not bestD or d < bestD) then best, bestD = stall, d end
        end
    end
    return best
end

local function stallArg(source, value)
    local key = value or cfg.stallOrder[1]
    local stall = Svc.stalls[key]
    if not stall or not stall.opened then
        reply(source, "unknown or closed stall " .. tostring(key))
        return nil
    end
    return stall
end

local function requestFor(pid, action, target, options)
    local op, why, info = P.actions.request(pid, action, target, options)
    if not op then Svc:refuseTo(pid, why) end
    return op, why, info
end

local function describeCounts(snap)
    local parts = {}
    for item, n in pairs(type(snap) == "table" and snap.items or {}) do parts[#parts + 1] = item .. "=" .. n end
    table.sort(parts)
    return table.concat(parts, ",")
end

-- Player: /streetfood [menu | order <dish> | tip <eddies> | eat [dish] | drink | serve | stock | orders]
RegisterCommand("streetfood", function(source, args)
    local pid = M.playerId(source)
    if not pid then return print("[rp_streetfood] /streetfood is a player command; the console uses streetfood.lab.*") end
    if not Svc.ready then return Svc:tell(pid, M.textFor("streetfood_unavailable"), "warning") end
    local verb = args and args[1] or ""
    CreateThread(function()
        if verb == "menu" then
            local stall = nearestStall(pid, "counter", 15.0)
            local parts = {}
            local pass = stall and L.read(stall.pass)
            local pantry = stall and L.read(stall.pantry)
            for _, key in ipairs(cfg.menuOrder) do
                local m = cfg.menu[key]
                local ready = stall and L.available(m.from == "pass" and pass or pantry, m.item) or 0
                parts[#parts + 1] = ("%s %s (%d ready)"):format(m.label, M.money(m.price), ready)
            end
            Svc:tell(pid, "Menu: " .. table.concat(parts, "; "), "info")
        elseif verb == "order" then
            local dish = args[2]
            if not cfg.menu[dish or ""] then return Svc:tell(pid, M.textFor("unknown_dish"), "warning") end
            local stall = nearestStall(pid, "counter", cfg.maxDistance)
            if not stall then return Svc:refuseTo(pid, "too_far") end
            requestFor(pid, "order_" .. dish, stall.key .. "_counter")
        elseif verb == "tip" then
            local tip, why = Svc:setTip(pid, args[2])
            if not tip then return Svc:refuseTo(pid, why) end
            Svc:tell(pid, ("Tip for your next order: %s."):format(M.money(tip)), "info")
        elseif verb == "eat" then
            requestFor(pid, "eat_go", nil, args[2] and { data = { dish = args[2] } } or nil)
        elseif verb == "drink" then
            requestFor(pid, "drink_go", nil, args[2] and { data = { dish = args[2] } } or nil)
        elseif verb == "serve" or verb == "stock" then
            local stall = nearestStall(pid, "grill", cfg.maxDistance)
            if not stall then return Svc:refuseTo(pid, "too_far") end
            requestFor(pid, verb, stall.key .. "_grill")
        elseif verb == "orders" then
            local stall = nearestStall(pid, "grill", 15.0)
            local list = stall and M.ticketsInOrder(Svc.tickets[stall.key]) or {}
            local parts = {}
            for _, t in ipairs(list) do parts[#parts + 1] = ("#%d %s for %s"):format(t.seq, t.dish, Svc:nameOf(t.pid)) end
            Svc:tell(pid, #parts > 0 and ("Orders: " .. table.concat(parts, "; ")) or "No order waiting.", "info")
        else
            Svc:tell(pid, "Street food: order at the counter (E) or /streetfood order <skewer|burger|soda>, " ..
                "/streetfood tip <eddies>, accept the cook's hand-over to pay, then eat at the counter (E), " ..
                "/streetfood eat or /streetfood drink. Cooks: clock in (/service), grill (E), serve (E), " ..
                "/streetfood orders, /streetfood stock.", "info")
        end
    end)
end, false)

-- Operator / integrator (restricted: console, or ACL command.streetfood.*)
RegisterCommand("streetfood.status", function(source)
    local s = Svc.stats
    local offers, doubts, sales = 0, 0, 0
    for _ in pairs(Svc.offers) do offers = offers + 1 end
    for _ in pairs(Svc.doubts) do doubts = doubts + 1 end
    for _ in pairs(Svc.sales) do sales = sales + 1 end
    reply(source, ("ready=%s seating=%s targets=%s | cooks=%d sales=%d meals=%d orders=%d stocked=%d restocks=%d " ..
        "needs=%d declined=%d dropped=%d refusals=%d doubts=%d | open offers=%d cook/meal doubts=%d sale doubts=%d")
        :format(tostring(Svc.ready), cfg.seating.enabled and "on" or "off", tostring(Svc.targetCount), s.cooks, s.sales,
        s.meals, s.orders, s.stocked, s.restocks, s.needs, s.declined, s.dropped, s.refusals, s.doubts, offers, doubts, sales))
end, true)

-- streetfood.lab.setup <playerId> [cook|customer]: the cook job + duty (customers need nothing).
RegisterCommand("streetfood.lab.setup", function(source, args)
    local pid = argPlayer(source, args[1])
    if not pid then return end
    if args[2] == "customer" then
        return reply(source, ("player %d is a customer: needs cash only (/givemoney %d 200 if broke)"):format(pid, pid))
    end
    local ok, why = P.jobs.setJob(pid, cfg.job, 0)
    reply(source, ("setJob %d %s: %s %s"):format(pid, cfg.job, tostring(ok), tostring(why or "")))
    local on, dwhy = P.jobs.setDuty(pid, true, { job = cfg.job })
    reply(source, ("setDuty %d on: %s %s"):format(pid, tostring(on), tostring(dwhy or "")))
end, true)

-- streetfood.lab.clock <playerId> on|off
RegisterCommand("streetfood.lab.clock", function(source, args)
    local pid = argPlayer(source, args[1])
    if not pid then return end
    local ok, why = P.jobs.setDuty(pid, args[2] ~= "off", { job = cfg.job })
    reply(source, ("duty %d %s: %s %s"):format(pid, args[2] or "on", tostring(ok), tostring(why or "")))
end, true)

-- streetfood.lab.seed [stall] [times]: restock the pantry (cfg.seed x times, minted from the supplier).
RegisterCommand("streetfood.lab.seed", function(source, args)
    local stall = stallArg(source, args[1])
    if not stall then return end
    local times = math.tointeger(tonumber(args[2] or "1")) or 1
    local amounts = {}
    for item, n in pairs(cfg.seed) do amounts[item] = n * times end
    CreateThread(function()
        local receipt, why = Svc:restock(stall.key, amounts)
        reply(source, receipt and ("restock %s at %s: committed"):format(receipt.opId, stall.key)
            or ("restock refused: %s"):format(tostring(why)))
    end)
end, true)

-- streetfood.lab.give <playerId> <item> <count>: items into a player's pockets (rp_inventory addAsync).
RegisterCommand("streetfood.lab.give", function(source, args)
    local pid = argPlayer(source, args[1])
    if not pid then return end
    local item, n = args[2], math.tointeger(tonumber(args[3] or "1")) or 1
    if not cfg.items[item or ""] then return reply(source, "unknown item " .. tostring(item)) end
    CreateThread(function()
        local receipt, why = P.inventory.addAsync(pid, item, n, nil, { opId = L.newOpId("labgive") })
        reply(source, ("give %d %s to %d: %s %s"):format(n, item, pid, receipt and "ok" or "refused", tostring(why or "")))
    end)
end, true)

-- streetfood.lab.cook <playerId> <recipe> [stall]: the same request the grill prompt makes.
RegisterCommand("streetfood.lab.cook", function(source, args)
    local pid = argPlayer(source, args[1])
    if not pid then return end
    if not cfg.recipes[args[2] or ""] then return reply(source, "unknown recipe " .. tostring(args[2])) end
    local stall = stallArg(source, args[3])
    if not stall then return end
    local op, why, info = P.actions.request(pid, "cook_" .. args[2], stall.key .. "_grill")
    reply(source, op and ("cook %s at %s: op %s state %s"):format(args[2], stall.key, tostring(op.opId), tostring(op.state))
        or ("cook refused: %s (stage %s)"):format(tostring(why), tostring(info and info.stage)))
end, true)

-- streetfood.lab.stock <playerId> [stall]
RegisterCommand("streetfood.lab.stock", function(source, args)
    local pid = argPlayer(source, args[1])
    if not pid then return end
    local stall = stallArg(source, args[2])
    if not stall then return end
    local op, why = P.actions.request(pid, "stock", stall.key .. "_grill")
    reply(source, op and ("stock: op %s"):format(tostring(op.opId)) or ("stock refused: " .. tostring(why)))
end, true)

-- streetfood.lab.order <playerId> <dish> [tip] [stall]: the counter prompt's request.
RegisterCommand("streetfood.lab.order", function(source, args)
    local pid = argPlayer(source, args[1])
    if not pid then return end
    if not cfg.menu[args[2] or ""] then return reply(source, "unknown dish " .. tostring(args[2])) end
    local stall = stallArg(source, args[4])
    if not stall then return end
    if args[3] then
        local tip, why = Svc:setTip(pid, args[3])
        if not tip then return reply(source, "tip refused: " .. tostring(why)) end
    end
    local op, why, info = P.actions.request(pid, "order_" .. args[2], stall.key .. "_counter")
    reply(source, op and ("order %s: op %s"):format(args[2], tostring(op.opId))
        or ("order refused: %s (stage %s)"):format(tostring(why), tostring(info and info.stage)))
end, true)

-- streetfood.lab.serve <cookId> [stall]: the grill's "Serve the next order" prompt.
RegisterCommand("streetfood.lab.serve", function(source, args)
    local pid = argPlayer(source, args[1])
    if not pid then return end
    local stall = stallArg(source, args[2])
    if not stall then return end
    local op, why = P.actions.request(pid, "serve", stall.key .. "_grill")
    reply(source, op and ("serve: op %s (the offer follows in the log)"):format(tostring(op.opId))
        or ("serve refused: " .. tostring(why)))
end, true)

-- streetfood.lab.offer <cookId> <customerId> <dish> [tip] [stall]: an order and its hand-over offer in
-- one step (no customer prompt needed). The customer still has to accept: Y on the offer card, or
-- /interaction accept.
RegisterCommand("streetfood.lab.offer", function(source, args)
    local cook = argPlayer(source, args[1])
    local customer = cook and argPlayer(source, args[2])
    if not customer then return end
    local dish = args[3]
    if not cfg.menu[dish or ""] then return reply(source, "unknown dish " .. tostring(dish)) end
    local stall = stallArg(source, args[5])
    if not stall then return end
    CreateThread(function()
        local subject = L.subjectOf(customer)
        if args[4] then Svc:setTip(customer, args[4]) end
        local ticket = Svc:openTicket(stall.key, customer, subject, dish)
        local o, why = Svc:offer(cook, stall, { ticket = ticket })
        reply(source, o and ("offer %s: %s -> %s, %s, sale %s; the customer accepts with Y on the offer card, or /interaction accept")
            :format(o.id, tostring(cook), tostring(customer), dish, o.opId) or ("offer refused: " .. tostring(why)))
    end)
end, true)

-- streetfood.lab.eat <playerId> <counter|go|drink|seat:<n>> [dish] [stall]
RegisterCommand("streetfood.lab.eat", function(source, args)
    local pid = argPlayer(source, args[1])
    if not pid then return end
    local place = args[2] or "go"
    local options = args[3] and { data = { dish = args[3] } } or nil
    local stall = stallArg(source, args[4])
    if not stall then return end
    local action, target
    if place == "counter" then
        action, target = "eat_counter", stall.key .. "_counter"
    elseif place == "go" then
        action = "eat_go"
    elseif place == "drink" then
        action = "drink_go"
    else
        local index = math.tointeger(tonumber(place:match("^seat:(%d+)$") or ""))
        local id = index and ("%s_seat_%d"):format(stall.key, index)
        local seat = id and Svc.seats[id]
        if not seat then return reply(source, "no seat " .. tostring(place) .. " (seating " .. (cfg.seating.enabled and "on" or "off") .. ")") end
        action, target = "eat_seat_" .. (tostring(seat.profile):gsub("[^%w_]", "_")):sub(1, 38), id
    end
    local op, why, info = P.actions.request(pid, action, target, options)
    reply(source, op and ("%s: op %s state %s"):format(action, tostring(op.opId), tostring(op.state))
        or ("%s refused: %s (stage %s)"):format(action, tostring(why), tostring(info and info.stage)))
end, true)

-- streetfood.lab.state <playerId>: dishes in pockets, hand item, cash, open order, receipts.
RegisterCommand("streetfood.lab.state", function(source, args)
    local pid = argPlayer(source, args[1])
    if not pid then return end
    CreateThread(function()
        local subject, why = L.subjectOf(pid)
        if not subject then return reply(source, "no subject: " .. tostring(why)) end
        local pockets = L.read("char:" .. subject)
        local parts = {}
        for item, n in pairs(type(pockets) == "table" and pockets.items or {}) do
            if cfg.items[item] then parts[#parts + 1] = item .. "=" .. n end
        end
        table.sort(parts)
        local hand = Svc.hands[pid]
        local cash = P.economy.balanceOf({ subject = subject })
        local soc = P.economy.balanceOf({ society = cfg.society })
        reply(source, ("player %d subject %s pockets={%s} hand=%s cash=%s society %s=%s"):format(pid, subject,
            table.concat(parts, ","), hand and hand.record or "-", tostring(type(cash) == "table" and cash.balance),
            cfg.society, tostring(type(soc) == "table" and soc.balance)))
        for key, list in pairs(Svc.tickets) do
            if list[subject] then
                reply(source, ("order #%d at %s: %s tip %d"):format(list[subject].seq, key, list[subject].dish, list[subject].tip))
            end
        end
        for _, entry in ipairs(Svc.receipts[subject] or {}) do
            reply(source, ("receipt %s %s%s: %s"):format(entry.kind, entry.opId, entry.replay and " (replay)" or "", entry.text or ""))
        end
    end)
end, true)

-- streetfood.lab.stall [stall]: pantry and pass contents, promised portions, orders, offers, seats.
RegisterCommand("streetfood.lab.stall", function(source, args)
    local stall = stallArg(source, args[1])
    if not stall then return end
    CreateThread(function()
        local pantry, pass = Svc:stallSnapshot(stall)
        reply(source, ("stall %s pantry %s {%s} weightG=%s/%s"):format(stall.key, stall.pantry, describeCounts(pantry),
            tostring(type(pantry) == "table" and pantry.weightG), tostring(type(pantry) == "table" and pantry.capacityG)))
        reply(source, ("stall %s pass %s {%s} weightG=%s/%s"):format(stall.key, stall.pass, describeCounts(pass),
            tostring(type(pass) == "table" and pass.weightG), tostring(type(pass) == "table" and pass.capacityG)))
        for key, n in pairs(Svc.promised) do reply(source, ("promised %s: %d"):format(key, n)) end
        for _, t in ipairs(M.ticketsInOrder(Svc.tickets[stall.key])) do
            reply(source, ("order #%d %s for player %d tip %d"):format(t.seq, t.dish, t.pid, t.tip))
        end
        for id, o in pairs(Svc.offers) do
            reply(source, ("offer %s cook %d customer %d %s sale %s"):format(id, o.cook, o.customer, o.item, o.opId))
        end
        for id, seat in pairs(Svc.seats) do
            if seat.stall == stall.key then
                reply(source, ("seat %s %s furniture %s profile %s at %.3f,%.3f,%.3f yaw %.2f (%s)"):format(id, seat.label,
                    seat.furniture, seat.profile, seat.position.x, seat.position.y, seat.position.z, seat.yaw, seat.source))
            end
        end
    end)
end, true)
