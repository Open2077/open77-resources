-- Public, self-only read utilities. Do NOT add mutations to this registry.
-- These intentionally bypass Admin.register: no admin role is required.
local lastRead = {}
for _, kind in ipairs({"pos", "rot"}) do
    RegisterCommand(kind, function(playerId, args, raw)
        if playerId == nil or playerId <= 0 then
            return Admin.output(playerId, raw, false, "/" .. kind .. " is only available in game")
        end
        if (args.n or #args) ~= 0 then
            return Admin.output(playerId, raw, false, "usage: /" .. kind .. " (your own character)")
        end
        local now = Admin.nowMs()
        if lastRead[playerId] and now - lastRead[playerId] < 250 then return end
        lastRead[playerId] = now
        TriggerClientEvent("open77_admin:coordinates", playerId, kind)
    end, false)
end
RegisterNetEvent("chat:ready", function()
    TriggerClientEvent("chat:addSuggestions", source, {
        {command = "/pos", help = "Show and copy your world position.", parameters = {}},
        {command = "/rot", help = "Show and copy your orientation quaternion and yaw (degrees).", parameters = {}},
    })
end)
AddEventHandler("onPlayerDisconnected", function(id) lastRead[tonumber(id)] = nil end)
