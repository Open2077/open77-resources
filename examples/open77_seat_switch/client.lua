RegisterNetEvent('open77_seat_switch:message', function(message)
    print('seat demo: ' .. message)
end)

RegisterNetEvent('open77_seat_switch:local', function(action, value)
    local ok, reason
    if action == 'local' then
        ok, reason = Open77.vehicles.switchSeat(value)
    elseif action == 'localauto' and (value == 'on' or value == 'off') then
        ok, reason = Open77.vehicles.setAutoSeatSwitchEnabled(value == 'on')
    else return end
    print(('seat demo: %s queued=%s reason=%s'):format(action, tostring(ok), tostring(reason)))
end)

for _, suffix in ipairs({'Started', 'Completed', 'Failed'}) do
    AddEventHandler('open77:vehicleSeatSwitch' .. suffix, function(vehicle, id, before, after, reason)
        print(('seat demo local: %s id=%s vehicle=%s %s -> %s reason=%s'):format(suffix, id, vehicle, before, after, reason))
    end)
end
AddEventHandler('open77:vehicleSeatSwitchDecision', function(vehicle, id, seat, status, reason)
    print(('seat demo decision: %s id=%s vehicle=%s seat=%s reason=%s'):format(status, id, vehicle, seat, reason))
end)
