-- Trusted transparent compositor for resource-owned custom blip textures.
-- Downloaded resources never receive this surface handle; they only declare
-- an asset on Open77.blips and the native ownership layer drives the pixels.

local overlay

AddEventHandler("onClientResourceStart", function(name)
    if name ~= GetCurrentResourceName() then return end

    local reason
    overlay, reason = WebUI.create({
        entry = "web/index.html",
        layer = "system",
        width = 1920,
        height = 1080,
        fps = 60,
        zIndex = -100,
        transparent = true,
        visible = true
    })
    if not overlay then
        print("Open77 blip overlay failed: " .. tostring(reason))
    end
end)
