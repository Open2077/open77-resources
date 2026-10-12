-- Protected soft-death facade.
--
-- The C++ runtime owns all engine mutation and the server owns every life
-- transition. This package intentionally offers only durable reads and
-- forwards the canonical lifecycle events to resource authors.

local lastLocalState

local function refreshLocal()
    lastLocalState = Open77.players.getLifeState()
    return lastLocalState
end

AddEventHandler("onClientResourceStart", function(name)
    if name ~= GetCurrentResourceName() then return end
    refreshLocal()
end)

AddEventHandler("open77:playerLifeStateChanged", function(playerId, phase, revision)
    local state = Open77.players.getLifeState(tonumber(playerId))
    local session = Open77.network.status()
    if state and session and tonumber(session.playerId) == tonumber(playerId) then
        lastLocalState = state
    end
    TriggerEvent("open77:death:stateChanged", state, phase, tonumber(revision))
end)

exports("isDead", function(playerId)
    return Open77.players.isDead(playerId)
end)

exports("getState", function(playerId)
    return Open77.players.getLifeState(playerId)
end)

exports("getLocalDeathContext", function()
    return Open77.players.getLocalDeathContext() or lastLocalState
end)

exports("all", function()
    return Open77.players.allLifeStates()
end)
