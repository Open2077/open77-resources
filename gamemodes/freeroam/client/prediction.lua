-- Reuse the shipped city rules once at resource lifecycle boundaries. This is
-- a local event, with no network heartbeat or per-player server computation.
local function publish()
    local combat=FreeroamConfig.combat or {}
    local zones={}
    for _,spawn in ipairs((FreeroamConfig.spawn or {}).points or {}) do
        if spawn.position then zones[#zones+1]=spawn.position end
    end
    TriggerEvent("open77_prediction:policy",{owner=GetCurrentResourceName(),
        enabled=combat.pvpEnabled~=false,bucket=0,safeZoneRadius=combat.safeZoneRadius or 0,safeZones=zones,
        damageMultiplier=combat.damageMultiplier or 1,meleeMultiplier=combat.meleeMultiplier or 1,
        explosionMultiplier=combat.explosionMultiplier or 1,
        headshotMultiplier=combat.headshotMultiplier or 1})
end
AddEventHandler("open77_prediction:requestPolicy",publish)
AddEventHandler("onClientResourceStart",function(name) if name==GetCurrentResourceName() then publish() end end)
AddEventHandler("onClientResourceStop",function(name)
    if name==GetCurrentResourceName() then TriggerEvent("open77_prediction:policy",{enabled=false}) end
end)
