-- open77_forcedoor — server side
--
-- Registers the /forcedoor and /unlockdoor chat commands. When a player
-- types one of these, the server triggers a client event that does the
-- actual door manipulation via Open77.doors (client-side targeting +
-- door action API).
--
-- The command is restricted behind command.forcedoor so operators can
-- gate it with the ACL.

RegisterCommand("forcedoor", function(source, args, raw)
    if source == nil or source <= 0 then
        return
    end
    TriggerClientEvent("open77_forcedoor:execute", source, true)
end, false)

RegisterCommand("unlockdoor", function(source, args, raw)
    if source == nil or source <= 0 then
        return
    end
    TriggerClientEvent("open77_forcedoor:execute", source, false)
end, false)

print("[open77_forcedoor] ready -- /forcedoor /unlockdoor")
