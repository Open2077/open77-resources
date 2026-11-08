-- Server half: start a braindance transition that holds black, do something
-- the player must not see, then let the image come back.
local mine = {} -- id -> true, the sequences this resource started

AddEventHandler("open77_braindance:black", function(playerId, id, tag)
    if not mine[id] then return end
    print(("[bd-example] player %d is black (%s, tag %s): swapping the scene"):format(playerId, id, tostring(tag)))
    CreateThread(function()
        -- Anything invisible goes here: Open77.players.teleport, a bucket
        -- change, spawning props or NPCs, changing the weather...
        Wait(1500)
        local ok, reason = exports.open77_braindance:resume(playerId, id)
        print(("[bd-example] resume %s -> %s %s"):format(id, tostring(ok), tostring(reason or "")))
    end)
end)

AddEventHandler("open77_braindance:phase", function(playerId, id, phase, tag)
    print(("[bd-example] player %d %s -> %s (tag %s)"):format(playerId, id, phase, tostring(tag)))
    if phase == "finished" or phase == "cancelled" then mine[id] = nil end
end)

RegisterCommand("bdexample", function(_, args)
    local playerId = tonumber(args[1])
    if not playerId then return print("usage: bdexample <playerId> server|client") end
    if args[2] == "client" then
        TriggerClientEvent("open77_braindance_example:run", playerId)
        return print("[bd-example] asked the client to run its own sequence")
    end
    local id, reason = exports.open77_braindance:start(playerId, {
        preset = "transition", hold = true, maxHoldMs = 15000, tag = "server-example",
    })
    if id then mine[id] = true end
    print(("[bd-example] start -> %s %s"):format(tostring(id), tostring(reason or "")))
end, true)
