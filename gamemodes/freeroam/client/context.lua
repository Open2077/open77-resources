-- Gameplay belongs here, never in the generic targeting resource.
local resource = GetCurrentResourceName()
local function notify(message, ok)
    print("[freeroam] " .. message)
    local pending = Open77.exports.call("open77_notifications", "show", {
        title = "Freeroam", message = message, type = ok and "success" or "error",
    })
    if pending then pending:await() end
end

exports("contextAvailable", function(context)
    if GetInvokingResource() ~= "open77_contextmenu" then return false end
    local action, target = context.action.data.action, context.target
    if action == "playerId" then return type(target.playerId) == "number" and target.playerId > 0 end
    if action == "vehicleId" or action == "vehicleModel" then
        return type(target.vehicleId) == "number" and target.vehicleId > 0
    end
    return target.isLocalPlayer == true
end)

exports("contextSelect", function(context)
    if GetInvokingResource() ~= "open77_contextmenu" then return false end
    local action, target = context.action.data.action, context.target
    if action == "menu" or action == "animations" then
        return TriggerServerEvent("open77:command:execute", action == "menu" and "freeroam" or "anim")
    end
    local value
    if action == "playerId" then value = target.playerId
    elseif action == "vehicleId" then value = target.vehicleId
    elseif action == "vehicleModel" then
        local vehicle = Open77.vehicles.get(target.vehicleId)
        value = vehicle and vehicle.record
    end
    if value == nil then notify("Target is no longer available.", false); return false end
    local ok, reason = Open77.clipboard.setText(tostring(value))
    notify(ok and ("Copied: " .. tostring(value)) or ("Clipboard unavailable: " .. tostring(reason)), ok)
    return ok == true
end)

local function register()
    local definitions = {}
    local function add(id, label, kind, icon, selfOnly)
        definitions[#definitions + 1] = {
            id = id, label = label, types = {kind}, icon = icon, distance = 8,
            allowSelf = kind == "player", selfOnly = selfOnly == true,
            group = "Freeroam", order = #definitions,
            canInteract = "contextAvailable", onSelect = "contextSelect", data = {action = id},
        }
    end
    add("playerId", "Copy player ID", "player", "person")
    add("vehicleId", "Copy vehicle ID", "vehicle", "vehicle")
    add("vehicleModel", "Copy vehicle model", "vehicle", "info")
    add("menu", "Freeroam menu", "player", "interact", true)
    add("animations", "Animations", "player", "person", true)
    local pending, reason = Open77.exports.call("open77_contextmenu", "registerMany", definitions)
    if pending then local tokens; tokens, reason = pending:await(); if tokens then return end end
    print("[freeroam] context registration failed: " .. tostring(reason))
end
AddEventHandler("onClientResourceStart", function(name)
    if name == resource or name == "open77_contextmenu" then register() end
end)
