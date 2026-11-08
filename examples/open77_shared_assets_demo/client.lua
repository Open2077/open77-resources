local pages = {}
CreateThread(function()
    Wait(0)
    for index, name in ipairs({ "Inventory", "Admin panel" }) do
        local page, reason = WebUI.create({
            entry = "web/index.html",
            layer = "hud", zIndex = 500, width = 1280, height = 720, fps = 15,
            drawBounds = { x = 30 + (index - 1) * 490, y = 110, width = 460, height = 490 },
        })
        assert(page, reason)
        pages[#pages + 1] = page
        page:on("ui:ready", function() page:send("assets:consumer", { name = name, x = 30 + (index - 1) * 490 }) end)
        page:on("assets:result", function(result)
            print("shared-assets-demo " .. name .. " " .. json.encode(result))
        end)
    end
end)
RegisterCommand("shared-assets-hide", function()
    for _, page in ipairs(pages) do page:hide() end
end, false)
