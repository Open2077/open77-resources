-- Placement checks a level path, not the boss's entire footprint or the navmesh.
RegisterNetEvent("chimera:probePlacement", function(requestId, origin)
    local failure = "no level, unobstructed direction"
    for direction = 0, 15 do
        local angle = direction * math.pi / 8
        local dx, dy = math.cos(angle), math.sin(angle)
        local previous = { x = origin.x + dx * 1.2, y = origin.y + dy * 1.2, z = origin.z }
        local clear = true
        for step = 1, 4 do
            local distance = 18 * step / 4
            local x, y = origin.x + dx * distance, origin.y + dy * distance
            local ground, why = Open77.world.raycast(
                { x = x, y = y, z = origin.z + 3 }, { x = x, y = y, z = origin.z - 3 }, { dynamic = false })
            if not ground then failure = tostring(why); clear = false; break end
            if not ground.hit or not ground.position or not ground.normal or ground.normal.z < 0.85 or
                math.abs(ground.position.z - previous.z) > 1 then clear = false; break end
            local nextPoint = { x = x, y = y, z = ground.position.z }
            for _, height in ipairs({ 1, 2 }) do
                local obstruction, rayError = Open77.world.raycast(
                    { x = previous.x, y = previous.y, z = previous.z + height },
                    { x = nextPoint.x, y = nextPoint.y, z = nextPoint.z + height })
                if not obstruction then failure = tostring(rayError); clear = false; break end
                if obstruction.hit then clear = false; break end
            end
            if not clear then break end
            previous = nextPoint
        end
        if clear then TriggerServerEvent("chimera:placement", requestId, direction, previous.z); return end
    end
    TriggerServerEvent("chimera:placement", requestId, -1, origin.z, failure)
end)

AddEventHandler("open77:npcPlayerHit", function(victim, npc, epoch, amount, sequence)
    TriggerServerEvent("chimera:hit", victim, npc, epoch, amount, sequence)
end)
AddEventHandler("open77:chimeraFrame", function(npc, epoch, sequence, payload)
    if type(payload) == "string" and #payload <= 16384 then
        TriggerServerEvent("chimera:frame", npc, epoch, sequence, payload)
    end
end)
AddEventHandler("open77:chimeraVisuals", function(npc, epoch, sequence, payload)
    if type(payload) == "string" and #payload <= 16384 then
        TriggerServerEvent("chimera:visuals", npc, epoch, sequence, payload)
    end
end)
AddEventHandler("open77:chimeraReady", function(npc) TriggerServerEvent("chimera:ready", npc) end)
AddEventHandler("onNpcReady", function(npc) TriggerServerEvent("chimera:ready", npc) end)
AddEventHandler("open77:worldReady", function() TriggerServerEvent("chimera:ready", "0") end)
AddEventHandler("onClientResourceStart", function(name)
    if name == GetCurrentResourceName() then TriggerServerEvent("chimera:ready", "0") end
end)
