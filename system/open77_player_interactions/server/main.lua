-- Commands are only a UI adapter. Accept/cancel still go through the canonical
-- authenticated participant checks, not a privileged server-resource override.
RegisterCommand('interaction', function(player, args)
    if not player or player <= 0 then return end
    local action = args and args[1] or 'status'
    if action == 'accept' or action == 'decline' or action == 'cancel' then
        TriggerClientEvent('open77_player_interactions:command', player, action)
    else
        local state = Open77.playerInteractions.current(player)
        TriggerClientEvent('chat:addMessage', player, {type='system', author='INTERACTIONS',
            text=state and (state.kind..' · '..state.phase..' · /interaction cancel') or 'No active interaction.'})
    end
end, false)
