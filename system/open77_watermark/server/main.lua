-- Session watermark authority.
--
-- The client cannot be trusted to describe its own session, so the identity
-- shown in the overlay comes from here: the authenticated playerId, the
-- resolved player name and the persistent identifier GUID. The client asks
-- with watermark:ready and re-asks periodically; each answer is a full
-- snapshot for that player only.

RegisterNetEvent("watermark:ready", function()
    local playerId = source
    TriggerClientEvent("watermark:state", playerId, {
        playerId = playerId,
        name = Open77.players.name(playerId),
        identifier = Open77.players.identifier(playerId),
    })
end)

print("[open77_watermark] session identity provider ready")
