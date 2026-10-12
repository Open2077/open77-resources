-- Phase 0 laboratory, client half: the one thing the server cannot do itself.
--
-- E4 (ghost spectator) needs noclip, and noclip is a client-side travel call.
-- Everything else in the laboratory is server-authoritative and needs no client.

RegisterNetEvent("cordonlab:noclip", function(enabled)
    local on = enabled == true or enabled == "true" or enabled == 1 or enabled == "1"
    local ok, reason = pcall(Open77.travel.setNoclip, on)
    print(("[cordonlab] noclip %s -> %s %s"):format(tostring(on), tostring(ok), tostring(reason)))
end)

-- The pickup request, driven from the laboratory's server half.
--
-- `Open77.loot.requestPickup` exists ONLY on the client: a grant always begins
-- as a client network event that the server then validates for distance and
-- bucket. There is no server-side pickup, so a test that wants to exercise the
-- grant has to come through here.
RegisterNetEvent("cordonlab:pickup", function(dropId)
    local id = tonumber(dropId)
    if id == nil then return end
    local ok, reason = Open77.loot.requestPickup(id)
    print(("[cordonlab] pickup request drop=%d -> %s %s"):format(id, tostring(ok), tostring(reason)))
end)
