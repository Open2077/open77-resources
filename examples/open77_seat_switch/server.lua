-- Optional demonstration. Every player command targets only its caller.
local function reply(player, message)
    print(('seat demo player=%s %s'):format(player, message))
    TriggerClientEvent('open77_seat_switch:message', player, message)
end

RegisterCommand('seats', function(player, args)
    if player == 0 then return end
    local action = args[1] or 'status'
    if action == 'local' or action == 'localauto' then
        TriggerClientEvent('open77_seat_switch:local', player, action, args[2] or 'driver')
        return
    end
    if action == 'status' then
        reply(player, json.encode({
            seat = Open77.vehicles.getPlayerSeat(player),
            transition = Open77.vehicles.getPlayerSeatSwitch(player),
            autoSwitchEnabled = Open77.vehicles.isPlayerAutoSeatSwitchEnabled(player),
        }))
        return
    end
    local ok, result
    if action == 'auto' and (args[2] == 'on' or args[2] == 'off') then
        ok, result = Open77.vehicles.setPlayerAutoSeatSwitchEnabled(player, args[2] == 'on')
    elseif action == 'move' then
        ok, result = Open77.vehicles.switchPlayerSeat(player, args[2] or 'driver')
    elseif action == 'cancel' then
        local current = Open77.vehicles.getPlayerSeatSwitch(player)
        if not current then reply(player, 'No seat switch is running.'); return end
        ok, result = Open77.vehicles.cancelPlayerSeatSwitch(player, current.id)
    else
        reply(player, '/seats move <seat> | auto on/off | cancel | status | local <seat> | localauto on/off')
        return
    end
    reply(player, ('%s accepted=%s result=%s'):format(action, tostring(ok), tostring(result)))
end, false)

for _, suffix in ipairs({'Started', 'Completed', 'Failed'}) do
    AddEventHandler('onPlayerVehicleSeatSwitch' .. suffix, function(player, vehicle, id, before, after, reason)
        reply(tonumber(player), ('%s id=%s vehicle=%s %s -> %s reason=%s'):format(suffix, id, vehicle, before, after, reason))
    end)
end
