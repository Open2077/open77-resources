-- open77_netdebug server: the admin toggle, and the player names the client labels with.

local enabled = {}   -- playerId -> true

local function names()
    local out = {}
    for _, id in ipairs(GetPlayers()) do
        local n = tonumber(id)
        if n then out[tostring(n)] = GetPlayerName(n) or ("player " .. n) end
    end
    return out
end

local function reply(player, text)
    if player and player > 0 then
        TriggerClientEvent("chat:addMessage", player, {
            type = "system", author = "NETDEBUG", text = text, color = { 0, 229, 255 },
        })
    else
        print("[open77_netdebug] " .. text)
    end
end

-- /netdebug.npc [on|off]  -- admin-gated (ACL command.netdebug.npc)
RegisterCommand("netdebug.npc", function(source, args)
    local player = tonumber(source)
    if not player or player <= 0 then reply(nil, "netdebug.npc is an in-game command"); return end
    local wanted = args[1]
    local on
    if wanted == "on" then on = true elseif wanted == "off" then on = false else on = not enabled[player] end
    enabled[player] = on or nil
    TriggerClientEvent("open77_netdebug:npc", player, on, names())
    reply(player, on and "NPC network labels ON (nearest 8 within 60 m)" or "NPC network labels OFF")
end, true)

-- Names change as players come and go: refresh them for whoever is watching.
CreateThread(function()
    while true do
        Wait(5000)
        if next(enabled) then
            local list = names()
            for player in pairs(enabled) do TriggerClientEvent("open77_netdebug:names", player, list) end
        end
    end
end)

AddEventHandler("playerDropped", function()
    local id = tonumber(source)
    if id then enabled[id] = nil end
end)
