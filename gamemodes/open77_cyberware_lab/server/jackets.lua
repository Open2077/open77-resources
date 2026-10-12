-- Optional acceptance control; every mutation uses the public clothing relay.
CyberwareLabJackets = {}
local saved, stopped = {}, false
local function log(player, phase, request, reason, state)
    print(("[cyberware lab] jacket player=%s phase=%s request=%s reason=%s restore=%s")
        :format(player, phase, tostring(request), tostring(reason),
            state and state.captured and (state.original or "<empty>") or "<not_captured>"))
end
local function dispatch(player, state)
    state.phase = "applying"
    local request, reason = Open77.clothing.set(player, {
        outer_chest = state.record,
    })
    state.request = request
    if not request then state.phase = "saved" end
    log(player, state.phase, request, reason, state)
    return request ~= nil, request or reason
end
function CyberwareLabJackets.start(player, record)
    if stopped then return false, "resource_stopping" end
    if not player or player < 1 or player % 1 ~= 0 then return false, "invalid_player" end
    if saved[player] then return false, "jacket_reserved_restore_first" end
    local count = 0
    for _ in pairs(saved) do count = count + 1 end
    if count >= 8 then return false, "jacket_backup_limit" end
    record = record or "Items.Jacket_01_basic_01"
    if type(record) ~= "string" or #record > 160 or not record:match("^Items%.[%w_]+$") then
        return false, "invalid_record"
    end
    local state = {phase="snapshot", record=record}
    saved[player] = state
    local request, reason = Open77.clothing.requestSnapshot(player)
    state.request = request
    if not request then saved[player] = nil end
    log(player, "snapshot", request, reason, state)
    return request ~= nil, request or reason
end
function CyberwareLabJackets.restore(player)
    if stopped then return false, "resource_stopping" end
    local state = saved[player]
    if not state then return false, "no_jacket_backup" end
    if state.phase ~= "saved" then return false, "jacket_request_pending" end
    state.phase = "restoring"
    local request, reason = Open77.clothing.set(player, {outer_chest=state.original})
    state.request = request
    if not request then state.phase = "saved" end
    log(player, state.phase, request, reason, state)
    return request ~= nil, request or reason
end
AddEventHandler("open77:clothing:completed", function(player, request, operation, accepted, reason, result)
    player = tonumber(player)
    local state = saved[player]
    if stopped or not state or not state.request or state.request ~= request then return end
    local phase = state.phase
    if (phase == "snapshot" and operation ~= "all") or
        ((phase == "applying" or phase == "restoring") and operation ~= "set") then return end
    state.request = nil
    log(player, phase .. "_completed", request, "accepted=" .. tostring(accepted) .. " " .. tostring(reason), state)
    if phase == "snapshot" then
        if not accepted or type(result) ~= "table" then saved[player] = nil; return end
        local row
        for _, entry in ipairs(result) do
            if type(entry) == "table" and entry.slot == "outer_chest" then
                if row then saved[player] = nil; log(player,"snapshot_invalid",request,"duplicate_slot"); return end
                row = entry
            end
        end
        if not row or type(row.equipped) ~= "boolean" or
            (row.equipped and (type(row.record) ~= "string" or #row.record == 0)) then
            saved[player] = nil; log(player,"snapshot_invalid",request,"missing_original"); return
        end
        state.original = row.equipped and row.record or false
        state.captured = true
        dispatch(player, state)
    elseif phase == "restoring" and accepted then
        saved[player] = nil
        log(player, "restored", request, reason, state)
    else
        -- Retain the original even after failure/timeout: native mutation may
        -- have happened before its acknowledgement was lost.
        state.phase = "saved"
    end
end)
AddEventHandler("onPlayerDisconnected", function(player)
    player = tonumber(player)
    local state = saved[player]
    if state then log(player,"disconnected_backup",state.request,"manual_restore_if_changed",state) end
    saved[player] = nil -- never apply a late completion to a recycled player ID
end)
AddEventHandler("onResourceStop", function(name)
    if name ~= GetCurrentResourceName() then return end
    stopped = true
    for player, state in pairs(saved) do log(player,"stop_backup",state.request,"manual_restore_if_changed",state) end
    saved = {}
end)
