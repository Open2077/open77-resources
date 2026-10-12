RegisterCommand('pointing', function(player, args)
    if player == 0 then return end
    local action = args[1] or 'status'
    if action ~= 'on' and action ~= 'off' and action ~= 'status' then return end
    TriggerClientEvent('open77_pointing:command', player, action)
end, false)
