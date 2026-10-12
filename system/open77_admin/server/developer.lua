-- Developer overlays are private to the requesting operator. The short lease
-- also removes them after a lost session, revoked ACL or server resource stop.
local command = "admin.dev.doors.inspect"
local enabled = {}
Admin.register("admin.dev.doors.control", {
    help = "Manage a nearby synchronized door; lift movement remains elevator-controlled.",
    params = {{name="id"}, {name="open|close|lock|unlock|seal|unseal|automatic"}},
    requiresPlayer = true, mutation = true,
    handler = function(player, args, raw)
        local pending, reason = Open77.exports.call("open77_doors", "adminControl", player, args[1], args[2])
        local ok = false
        if pending then ok, reason = pending:await() end
        local detail = tostring(args[1]) .. " " .. tostring(args[2])
        Admin.output(player, raw, ok == true, ok and ("Door updated: " .. detail) or ("Door: " .. tostring(reason)))
        return ok == true, detail .. (reason and (" " .. tostring(reason)) or "")
    end,
})
local function send(player, value)
    return Admin.push(player, "doorInspector", { enabled = value == true })
end

Admin.register(command, {
    help = "Toggle the nearby native Door Inspector (on/off).",
    params = { { name = "mode", help = "on / off / toggle" } },
    requiresPlayer = true,
    mutation = true,
    handler = function(player, args, raw)
        local mode = tostring(args[1] or "toggle"):lower()
        if mode ~= "on" and mode ~= "off" and mode ~= "toggle" then
            return Admin.output(player, raw, false, "Usage: /" .. command .. " [on|off|toggle]")
        end
        local value = mode == "on" or (mode == "toggle" and not enabled[player])
        enabled[player] = value or nil
        if not send(player, value) then
            enabled[player] = nil
            return Admin.output(player, raw, false, "Door Inspector could not be delivered; try again.")
        end
        local message = "Door Inspector " .. (value and "ON — local debug only" or "OFF")
        Admin.output(player, raw, true, message)
        return true, message
    end,
})

AddEventHandler("onPlayerDisconnected", function(id) enabled[tonumber(id)] = nil end)
CreateThread(function()
    while true do
        for player in pairs(enabled) do
            if Open77.players.name(player) == nil then
                enabled[player] = nil
            elseif not Admin.allowed(player, command) then
                enabled[player] = nil
                send(player, false)
            else
                send(player, true)
            end
        end
        Wait(1000)
    end
end)
AddEventHandler("onResourceStop", function(name)
    if name ~= GetCurrentResourceName() then return end
    for player in pairs(enabled) do send(player, false) end
    enabled = {}
end)
