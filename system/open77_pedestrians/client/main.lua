-- The platform emits `open77:npcHit` only on the shooter's client, for any Open77 NPC;
-- the server keeps the hits that land on one of its pedestrians and prices them itself.
AddEventHandler("open77:npcHit", function(npcId)
    if npcId ~= nil then TriggerServerEvent("open77_pedestrians:hit", { npcId = npcId }) end
end)
