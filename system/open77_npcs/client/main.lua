-- Client NPC state is intentionally read-only. The server owns canonical state.
AddEventHandler("onNpcStreamIn", function(npcId, revision)
    print(string.format("NPC streamed in id=%s revision=%s", npcId, revision))
end)

AddEventHandler("onNpcStreamOut", function(npcId, reason)
    print(string.format("NPC streamed out id=%s reason=%s", npcId, reason))
end)

AddEventHandler("onNpcReady", function(npcId, entity)
    local npc = Open77.npcs.get(npcId)
    print(string.format("NPC ready id=%s entity=%s template=%s", npcId, entity,
        npc and npc.template or "unknown"))
end)

AddEventHandler("onNpcChanged", function(npcId, revision)
    local npc = Open77.npcs.get(npcId)
    if npc ~= nil then
        print(string.format("NPC changed id=%s revision=%s health=%.1f", npcId, revision, npc.health))
    end
end)

RegisterNetEvent("open77:npcs:dump", function()
    for _, npc in ipairs(Open77.npcs.all()) do
        print(string.format("npc=%s entity=%s streamed=%s authority=%s health=%.1f/%.1f",
            tostring(npc.id), tostring(npc.entity), tostring(npc.streamed),
            tostring(npc.locallyAuthoritative), npc.health, npc.maxHealth))
    end
end)
