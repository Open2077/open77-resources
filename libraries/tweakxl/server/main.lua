-- Marker only: the loader itself is a launcher-installed package (see open77.lua).
AddEventHandler("onResourceStart", function(resource)
    if resource ~= GetCurrentResourceName() then return end
    print("[tweakxl] tweakxl 1.12.0 declared as a required mod (dist/TweakXL-1.12.0.zip)")
end)
