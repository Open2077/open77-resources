-- Open-by-default example policy. Server owners may replace this resource or
-- add their own authorization here; native lifecycle/revision checks still apply.
CyberwareLabPanel = {}
local pendingByTarget, pendingByTicket = {}, {}
local lastRead = {}

local function playerId(value)
    local id = tonumber(value)
    return id and id > 0 and id <= 9007199254740991 and id % 1 == 0 and id or nil
end

local function connected(value)
    local id = playerId(value)
    return id and Open77.players.name(id) ~= nil and id or nil
end

local function send(issuer, suffix, value)
    if connected(issuer) then TriggerClientEvent("open77:cyberlab:panel:" .. suffix, issuer, value) end
end

local function definitionFor(slot)
    if slot == "arms" then return CyberwareLab.definition end
    if slot == "legs" then return CyberwareLab.legsDefinition end
end

local function snapshot(issuer, target)
    local roster = {}
    for _, rawId in ipairs(Open77.players.all()) do
        local id = connected(rawId)
        if id then roster[#roster + 1] = { id = id, name = Open77.players.name(id) } end
    end
    table.sort(roster, function(a, b) return a.id < b.id end)
    local catalog = {}
    for _, slot in ipairs({"arms", "legs"}) do
        local definition = definitionFor(slot)
        if definition then
            catalog[#catalog + 1] = { slot = slot,
                label = slot == "arms" and "Gorilla Arms" or "Double Jump",
                definition = definition.id, grades = definition.grades }
        end
    end
    local available = connected(target)
    local record, reason
    if available then record, reason = Open77.cyberware.current(target) end
    return {
        you = { id = issuer, name = Open77.players.name(issuer) },
        target = { id = target, name = available and Open77.players.name(target) or "Disconnected player" },
        players = roster, catalog = catalog, record = record,
        dash = available and CyberwareLabDash and CyberwareLabDash.snapshot(target) or nil,
        effective = available and Open77.cyberware.effective(target) or nil,
        ready = record ~= nil, pending = pendingByTarget[target] ~= nil,
        reason = not available and "player_unavailable" or (not record and (reason or "cyberware_not_ready") or nil),
    }
end

local function result(issuer, target, slot, ok, phase, message, ticket)
    send(issuer, "result", { ok = ok, phase = phase, message = message,
        target = target, slot = slot, ticket = ticket })
end

function CyberwareLabPanel.open(issuer, target)
    issuer = connected(issuer)
    if not issuer then return false, "client_issuer_required" end
    target = target == nil and issuer or playerId(target)
    if not target then return false, "positive_player_required" end
    send(issuer, "open", snapshot(issuer, target))
    return true
end

RegisterNetEvent("open77:cyberlab:panel:request", function(payload)
    local issuer = connected(source)
    if not issuer then return end
    local target = payload
    if type(payload) == "table" then target = payload.target end
    target = target == nil and issuer or playerId(target)
    if not target then return end
    local now = GetGameTimer()
    if lastRead[issuer] and now - lastRead[issuer] < 100 then return end
    lastRead[issuer] = now
    send(issuer, "data", snapshot(issuer, target))
end)

RegisterNetEvent("open77:cyberlab:panel:action", function(payload)
    local issuer = connected(source)
    if not issuer then return end
    if type(payload) ~= "table" then
        result(issuer, issuer, nil, false, "failed", "invalid_action"); return
    end
    local target = payload.target == nil and issuer or playerId(payload.target)
    local slot, action, grade = payload.slot, payload.action, payload.grade
    if not target or not connected(target) then
        result(issuer, target, slot, false, "failed", "player_unavailable"); return
    end
    if slot == "dash" and CyberwareLabDash then
        local ok, message = CyberwareLabDash.operate(issuer,target,action,payload.preset,payload.mode)
        result(issuer,target,slot,ok,ok and "complete" or "failed",message)
        send(issuer,"data",snapshot(issuer,target))
        return
    end
    local definition = definitionFor(slot)
    if not definition or (action ~= "install" and action ~= "remove") then
        result(issuer, target, slot, false, "failed", "invalid_action"); return
    end
    if action == "install" then
        local found = false
        for _, item in ipairs(definition.grades or {}) do if item.id == grade then found = true; break end end
        if not found then result(issuer, target, slot, false, "failed", "unknown_grade"); return end
    end
    if pendingByTarget[target] then
        result(issuer, target, slot, false, "failed", "operation_pending"); return
    end
    local record, reason = Open77.cyberware.current(target)
    if not record then
        result(issuer, target, slot, false, "failed", reason or "cyberware_not_ready"); return
    end
    if action == "remove" and not record[slot] then
        result(issuer, target, slot, false, "failed", "implant_not_installed"); return
    end
    local operationId, operationError = Open77.cyberware.newOperationId()
    if not operationId then
        result(issuer, target, slot, false, "failed", operationError or "operation_id_unavailable"); return
    end
    local options = { expectedRevision = record.revision, operationId = operationId, slot = slot }
    local operation, error
    if action == "install" then
        operation, error = Open77.cyberware.install(target, definition.id, grade, options)
    else
        operation, error = Open77.cyberware.remove(target, options)
    end
    if not operation or not operation.ok then
        result(issuer, target, slot, false, "failed", error or "operation_refused"); return
    end
    if operation.ticket then
        local pending = { issuer = issuer, target = target, slot = slot, action = action, ticket = operation.ticket }
        pendingByTarget[target], pendingByTicket[operation.ticket] = pending, pending
        result(issuer, target, slot, true, "pending", action == "install" and "Installing implant..." or "Removing implant...", operation.ticket)
    else
        result(issuer, target, slot, true, "complete", action == "install" and "Implant installed." or "Implant removed.")
    end
    send(issuer, "data", snapshot(issuer, target))
end)

AddEventHandler("onCyberwareOperationCompleted", function(patient, ticket, encoded)
    local pending = pendingByTicket[ticket]
    if not pending or pending.target ~= playerId(patient) then return end
    local decoded, completion = pcall(json.decode, encoded)
    if not decoded or type(completion) ~= "table" then return end
    pendingByTicket[ticket] = nil
    if pendingByTarget[pending.target] == pending then pendingByTarget[pending.target] = nil end
    local ok = completion.ok == true
    result(pending.issuer, pending.target, pending.slot, ok, ok and "complete" or "failed",
        ok and (pending.action == "install" and "Implant installed." or "Implant removed.")
            or completion.error or "Operation failed.", ticket)
    send(pending.issuer, "data", snapshot(pending.issuer, pending.target))
end)

AddEventHandler("onPlayerDisconnected", function(rawId)
    local id = playerId(rawId)
    if not id then return end
    lastRead[id] = nil
    local pending = pendingByTarget[id]
    if pending then
        pendingByTarget[id], pendingByTicket[pending.ticket] = nil, nil
        result(pending.issuer, id, pending.slot, false, "failed", "player_disconnected", pending.ticket)
    end
    -- A submitted durable operation belongs to the target. Closing the UI or
    -- disconnecting its issuer does not fabricate a rollback of that operation.
end)

RegisterNetEvent("chat:ready", function()
    if connected(source) then TriggerClientEvent("chat:addSuggestions", source, {
        { command = "/cyberlab", help = "Open cyberware controls for yourself or another player.", parameters = {} },
    }) end
end)
