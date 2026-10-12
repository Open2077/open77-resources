-- An optional consumer, not part of open77_contextmenu. Availability is UI
-- guidance only: every mutation still travels through a restricted command.
local resource = GetCurrentResourceName()
local access = {commands = {}}
RegisterNetEvent("open77_admin:data", function(channel, payload)
    if type(payload) ~= "table" then return end
    if channel == "access" then access = payload
    elseif channel == "menu" and type(payload.access) == "table" then access = payload.access end
end)

local function available(context)
    if GetInvokingResource() ~= "open77_contextmenu" then return false end
    local d, t = context.action.data, context.target
    if not access.commands or access.commands.admin ~= true or access.commands[d.permission] ~= true then return false end
    if t.kind == "player" then return type(t.playerId) == "number" and t.playerId > 0 end
    if t.kind == "vehicle" then return type(t.vehicleId) == "number" and t.vehicleId > 0 end
    if t.kind == "door" then
        if type(t.engineEntity) ~= "string" then return false end
        local door = Open77.doors.state(t.engineEntity)
        return door ~= nil and not (door.lift and (d.mode == "open" or d.mode == "close"))
    end
    return context.kind == "sky"
end
exports("contextAvailable", available)
exports("contextSelect", function(context)
    if not available(context) then return false end
    local t, d = context.target, context.action.data
    if t.kind == "door" then
        -- Native parser accepts decimal uint64 strings and returns a canonical
        -- hexadecimal ID. Never round engine identities through a Lua double.
        local door = Open77.doors.state(t.engineEntity)
        if not door then return false end
        if d.mode == "copyDoor" then
            local ok = Open77.clipboard.setText(door.id) == true
            TriggerEvent("open77_admin:notice", {text=ok and ("Door ID copied: " .. door.id) or "Clipboard unavailable."})
            return ok
        end
        return Open77AdminContextMenu.open(d.mode, door)
    end
    return Open77AdminContextMenu.open(d.mode, t.playerId or t.vehicleId)
end)

local function register()
    local definitions = {}
    local function add(id, label, kind, permission, mode, icon, danger)
        definitions[#definitions + 1] = {id=id, label=label, types={kind},
            group="Administration", order=100+#definitions, distance=10, allowSelf=kind=="player",
            icon=icon or "tool", danger=danger==true, canInteract="contextAvailable", onSelect="contextSelect",
            data={permission=permission, mode=mode}}
    end
    add("player", "Manage player", "player", "admin.read.players", "player", "person")
    add("heal", "Heal player", "player", "admin.player.heal", "heal", "interact")
    add("revive", "Revive player", "player", "admin.player.revive", "revive", "interact")
    add("kick", "Kick player…", "player", "admin.moderate.kick", "kick", "lock", true)
    add("ban", "Ban player…", "player", "admin.moderate.ban", "ban", "lock", true)
    add("repair", "Repair body / glass", "vehicle", "admin.veh.repair", "repair", "tool")
    add("fullRepair", "Full repair (empty vehicle)", "vehicle", "admin.veh.repair", "fullRepair", "tool")
    add("vehicle", "Manage vehicle", "vehicle", "admin.veh.flag", "vehicle", "vehicle")
    add("delete", "Delete vehicle…", "vehicle", "admin.veh.remove", "remove", "tool", true)
    add("doorId", "Copy door ID", "door", "admin.dev.doors.inspect", "copyDoor", "info")
    add("door", "Manage door", "door", "admin.dev.doors.control", "door", "tool")
    add("openDoor", "Open door", "door", "admin.dev.doors.control", "open", "interact")
    add("closeDoor", "Close door", "door", "admin.dev.doors.control", "close", "lock")
    add("time", "Change time…", "sky", "weather.time.set", "time", "location")
    add("weather", "Change weather…", "sky", "weather.set", "weather", "location")
    -- Bound each export invocation below the live client's VM instruction
    -- budget (the registry validates and copies every definition).
    for first = 1, #definitions, 5 do
        local batch = {}
        for i = first, math.min(first + 4, #definitions) do batch[#batch+1] = definitions[i] end
        local pending, reason = Open77.exports.call("open77_contextmenu", "registerMany", batch)
        local tokens
        if pending then tokens, reason = pending:await() end
        if not tokens then
            local clear = Open77.exports.call("open77_contextmenu", "clear")
            if clear then clear:await() end
            print("[open77_admin] context registration failed: " .. tostring(reason))
            return
        end
    end
    print("[open77_admin] 15 context actions registered (ACL-filtered)")
end
AddEventHandler("onClientResourceStart", function(name)
    if name == resource or name == "open77_contextmenu" then register() end
end)
AddEventHandler("onClientResourceStop", function(name)
    if name == resource then access = {commands={}} end
end)
