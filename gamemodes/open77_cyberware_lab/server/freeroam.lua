-- Freeroam's public movement loadout. Wait for real gameplay and asynchronous
-- implant projection before granting Combined; never loop-install a pending ticket.
local pending, retryAt = {}, {}
local stopped = false

AddEventHandler("onCyberwareOperationCompleted", function(player, ticket)
    player = tonumber(player)
    if pending[player] == ticket then pending[player] = nil end
end)
AddEventHandler("onPlayerDisconnected", function(player)
    player = tonumber(player)
    pending[player], retryAt[player] = nil, nil
end)
AddEventHandler("onResourceStop", function(resource)
    if resource == GetCurrentResourceName() then stopped = true end
end)

CreateThread(function()
    while not stopped do
        Wait(1000)
        if stopped then return end
        if GetResourceState("freeroam") == "running" then
            for _, value in ipairs(Open77.players.all()) do
                local player = tonumber(value)
                local life = Open77.players.getLifeState(player)
                if Open77.ready.isReady(player) and life and life.phase == "alive"
                    and not pending[player] and GetGameTimer() >= (retryAt[player] or 0) then
                    -- Keep an existing owner/preset; supply Street Overdrive to
                    -- everyone else, regranting only after actual lifecycle loss.
                    if Open77.reflex and not Open77.reflex.current(player) then
                        retryAt[player] = GetGameTimer() + 5000
                        CyberwareLabReflex.operate(player, player, "grant", "street")
                    end
                    local record = Open77.cyberware.current(player)
                    if record then
                        local legs = record.legs
                        if not legs or legs.definition ~= CyberwareLab.legsDefinition.id
                            or not legs.grade or legs.grade.id ~= "athlete" then
                            retryAt[player] = GetGameTimer() + 5000
                            local operationId = Open77.cyberware.newOperationId()
                            if operationId then
                                local result = Open77.cyberware.install(player,
                                    CyberwareLab.legsDefinition.id, "athlete", {
                                        slot = "legs", expectedRevision = record.revision,
                                        operationId = operationId,
                                    })
                                if result and result.ok then pending[player] = result.ticket end
                            end
                        else
                            local current = Open77.dash.current(player)
                            if not current or (current.ownedByCaller == true and
                                current.projection.definition.id ~= "cyberlab.dash.advanced.combined") then
                                retryAt[player] = GetGameTimer() + 5000
                                CyberwareLabDash.operate(player, player, "install", "advanced", "combined")
                            end
                        end
                    end
                end
            end
        end
    end
end)
