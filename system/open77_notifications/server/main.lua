RegisterNetEvent("chat:ready", function()
    TriggerClientEvent("chat:addSuggestions", source, {{
        command = "/notification.test",
        help = "Display a WebUI notification test.",
        parameters = {{ name = "info|success|warning|error", optional = true }},
    }})
end)

RegisterCommand("notification.test", function(source, args, raw)
    if source == nil or source <= 0 then
        print("notification.test must be issued by an authenticated in-game admin")
        return
    end
    local kind = tostring(args[1] or "success"):lower()
    local id, reason = Open77.notifications.send(source, {
        id = "admin_test",
        type = kind,
        title = "Open77 notifications",
        message = "The WebUI notification system is ready.",
        durationMs = 5000,
        position = "middle_left",
        icon = kind == "success" and "OK" or string.upper(kind:sub(1, 1)),
        replace = true,
    })
    TriggerClientEvent("open77:command:result", source, raw or "notification.test",
        id ~= nil, id and ("notification queued id=" .. tostring(id)) or tostring(reason))
end, true)

print("Open77 notification service ready; use notification.test")
