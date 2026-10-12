-- Self recovery uses a physical hold, independent of teammate tap-to-revive.
-- A short server heartbeat lease cancels a hold if this client stops reporting.
local state, receivedAt, requested, wasDown, blocked, nextPulse = nil, 0, false, false, true, 0
local function now() return Open77.time.monotonic() * 1000 end
local function cancel()
    if requested then TriggerServerEvent("cordon:selfReviveCancel") end
    requested = false
end
AddEventHandler("cordon:state:local", function(payload)
    if type(payload) ~= "table" then return end
    if state and state.matchId ~= payload.matchId then cancel(); blocked = true end
    state, receivedAt = payload, now()
    local mine = type(payload.self) == "table" and payload.self or {}
    if type(mine.downed) ~= "table" then cancel(); blocked = true end
    if mine.downed and mine.downed.pending then requested = false end
end)
RegisterNetEvent("cordon:notice", function(payload)
    local kind = type(payload) == "table" and payload.kind or nil
    if kind == "reviveRefused" or kind == "reviveCancelled" then
        requested, blocked = false, true
    end
end)
AddEventHandler("onClientResourceStop", function(name)
    if name == "open77_cordon" then cancel(); state = nil end
end)
local function tick()
    local at = now()
    local down = Open77.input.isDown("F") == true
    local captured = Open77.input.isCaptured() == true
    local mine = state and type(state.self) == "table" and state.self or {}
    local info = type(mine.downed) == "table" and mine.downed or nil
    local elapsed = at - receivedAt
    local eligible = info ~= nil and state.participant == true and mine.state == "dead"
        and (state.phase == "live" or state.phase == "extraction")
        and elapsed >= 0 and elapsed < 1500 and not captured
        and (tonumber(info.remainingMs) or 0) > elapsed
    local pending = info and (info.pending == true or
        (type(mine.revive) == "table" and mine.revive.pending == true))
    if pending then requested = false; blocked = true
    elseif not eligible then cancel(); blocked = true
    elseif not down then cancel(); blocked = false
    elseif (tonumber(info.selfReadyInMs) or math.huge) > elapsed then
        cancel(); blocked = true
    elseif not blocked and not wasDown and not requested and mine.revive == nil then
        requested, nextPulse = true, at
        TriggerServerEvent("cordon:selfRevive")
    end
    if requested and down and at >= nextPulse then
        TriggerServerEvent("cordon:selfRevivePulse")
        nextPulse = at + 250
    end
    if not down and eligible and not pending then blocked = false end
    wasDown = down
end
CreateThread(function()
    while true do
        local ok, error = pcall(tick)
        if not ok then cancel(); blocked = true; Open77.log.warn("self-revive input: " .. tostring(error)) end
        Wait(50)
    end
end)
