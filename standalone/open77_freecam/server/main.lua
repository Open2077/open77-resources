-- Restricted command: server ACL checks the authenticated sender, never an ID
-- supplied by the client. F9 goes through this same command dispatcher.
RegisterCommand('freecam', function(player, args, raw)
    if not player or player <= 0 then return end
    local action = args[1] or 'toggle'
    if #args > 1 or (action ~= 'toggle' and action ~= 'on' and action ~= 'off' and action ~= 'state') then
        return TriggerClientEvent('open77:command:result', player, raw, false,
            'Usage: /freecam [on|off|state]')
    end
    local actor = Open77.players.get(player)
    if not actor or not actor.ready then return end
    TriggerClientEvent('open77:freecam:command', player, action)
end, true)
