-- Marker only: the loader itself is a launcher-installed package (see open77.lua).
AddEventHandler("onResourceStart", function(resource)
    if resource ~= GetCurrentResourceName() then return end
    print("[archivexl] archivexl 1.28.6 declared as a required mod (dist/ArchiveXL-1.28.6.zip)")
end)
