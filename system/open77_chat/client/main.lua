local chat
local enabled = true
local opened = false
local lastSuggestionRequest = -1000
local suggestionCount = 0

-- Parses `/command "an argument" plain\ value` into the exact string array
-- expected by the server's authenticated command dispatcher.
local function commandTokens(text)
    local source = tostring(text or ""):sub(2)
    local tokens, token, quote, escaped, started = {}, "", nil, false, false
    for index = 1, #source do
        local character = source:sub(index, index)
        if escaped then
            token = token .. character
            escaped = false
            started = true
        elseif character == "\\" then
            escaped = true
            started = true
        elseif quote ~= nil then
            if character == quote then quote = nil
            else token = token .. character end
            started = true
        elseif character == "\"" or character == "'" then
            quote = character
            started = true
        elseif string.match(character, "%s") then
            if started then
                tokens[#tokens + 1] = token
                token, started = "", false
                if #tokens > 32 then return nil, "Commands are limited to 32 arguments." end
            end
        else
            token = token .. character
            started = true
        end
    end
    if escaped then return nil, "A command cannot end with an escape character." end
    if quote ~= nil then return nil, "The command contains an unterminated quote." end
    if started then
        tokens[#tokens + 1] = token
        if #tokens > 32 then return nil, "Commands are limited to 32 arguments." end
    end
    if #tokens == 0 or tokens[1] == "" then return nil, "Enter a command after '/'." end
    return tokens
end

local function send(name, payload)
    if chat then chat:send(name, payload or {}) end
end

-- A8. Client commands are registered in the local runtime and never reach the
-- server, so the server's suggestion list cannot know about them. Merge them in
-- from the host registry on every refresh. Commands registered `restricted` are
-- left out on purpose: the client has no ACL, so `ExecuteCommand` refuses them,
-- and offering a completion for something that will not run is worse than
-- offering nothing. Guarded on the global's existence because a resource set is
-- served by the server while the runtime that hosts it ships with the client:
-- a newer chat can find itself on an older client.
local function mergeClientCommands()
    if type(GetRegisteredCommands) ~= "function" then return end
    local registered = GetRegisteredCommands()
    if type(registered) ~= "table" or #registered == 0 then return end
    local merged = {}
    for _, entry in ipairs(registered) do
        if type(entry) == "table" and not entry.restricted and type(entry.name) == "string" then
            merged[#merged + 1] = {
                command = "/" .. entry.name,
                help = entry.help or ("client command from " .. tostring(entry.resource)),
                parameters = entry.parameters or {}
            }
        end
    end
    if #merged > 0 then send("chat:addSuggestions", { suggestions = merged }) end
end

local function requestSuggestions()
    local now = Open77.time.monotonic()
    if now - lastSuggestionRequest < 0.75 then return true end
    lastSuggestionRequest = now
    mergeClientCommands()
    local accepted, reason = TriggerServerEvent("chat:ready")
    if not accepted then
        print("[open77_chat] suggestion request failed: " .. tostring(reason))
        return false
    end
    return true
end

local function closeChat()
    if not chat or not opened then return end
    opened = false
    chat:setFocus(false, false)
    send("chat:close", {})
    TriggerEvent("open77:chat:visibility", false)
end

local function openChat()
    -- Refusals are printed, not silent. "T does nothing" is the report this
    -- resource has to be able to answer, and each of these three is a different
    -- fault: no surface at all, a gamemode that turned the chat off, and a
    -- latched `opened` left behind by a close that never ran.
    if not chat then
        print("[open77_chat] open refused: the WebUI surface was never created")
        return
    end
    if not enabled then
        print("[open77_chat] open refused: the chat is disabled by the server")
        return
    end
    if opened then
        print("[open77_chat] open ignored: already open")
        return
    end
    opened = true
    -- Focus BEFORE the page is told to open, and that order is the point.
    -- `setFocus` reaches the WebHost as `CefBrowserHost::SetFocus`, while
    -- `chat:open` reaches the page as a script that ends up calling
    -- `input.focus()`. Both travel the same ordered pipe, so asking for browser
    -- focus first means the element focus lands in a browser that already has
    -- it, instead of racing a browser that does not yet.
    local focused = chat:setFocus(true, false)
    if not focused then
        print("[open77_chat] keyboard focus was refused; the box will take no text")
    end
    send("chat:open", {})
    TriggerEvent("open77:chat:visibility", true)
    requestSuggestions()
end

local function addMessage(message)
    if type(message) == "string" then message = { text = message } end
    if type(message) ~= "table" then return false end
    send("chat:addMessage", message)
    return true
end

RegisterNetEvent("chat:addMessage", addMessage)
RegisterNetEvent("chat:addSuggestion", function(command, help, parameters)
    send("chat:addSuggestion", {
        command = tostring(command or ""),
        help = tostring(help or ""),
        parameters = parameters or {}
    })
end)
RegisterNetEvent("chat:addSuggestions", function(suggestions)
    local count = type(suggestions) == "table" and #suggestions or 0
    suggestionCount = suggestionCount + count
    print(string.format("[open77_chat] received %d suggestions (total deliveries=%d)", count, suggestionCount))
    send("chat:addSuggestions", { suggestions = suggestions or {} })
end)
RegisterNetEvent("chat:removeSuggestion", function(command)
    send("chat:removeSuggestion", { command = tostring(command or "") })
end)
RegisterNetEvent("chat:clearSuggestions", function() send("chat:clearSuggestions", {}) end)
RegisterNetEvent("chat:addTemplate", function(id, template)
    send("chat:addTemplate", { id = tostring(id or ""), template = tostring(template or "") })
end)
RegisterNetEvent("chat:clear", function() send("chat:clear", {}) end)
RegisterNetEvent("chat:setEnabled", function(value)
    enabled = value ~= false
    if not enabled then closeChat() end
    send("chat:state", { enabled = enabled })
end)

RegisterNetEvent("open77:command:result", function(raw, accepted, message)
    raw, message = tostring(raw or ""), tostring(message or "")
    -- The dispatcher acknowledges queueing immediately. Commands that need to
    -- show output send a second, useful result; do not spam the HUD with both.
    if accepted and string.match(message, "^queued by ") then return end

    local text = message
    if not accepted and message == "unknown_command" then
        text = "Unknown command: /" .. raw
    elseif not accepted and string.match(message, "^permission_denied:") then
        text = "You do not have permission to run /" .. raw
    elseif text == "" then
        text = accepted and "Command completed." or "Command failed."
    end
    addMessage({
        type = accepted and "system" or "error",
        author = "COMMAND",
        text = text,
        color = accepted and { 0, 229, 255 } or { 255, 76, 92 }
    })
end)

-- Other HUDs may reserve the left-hand space while the composer is open.
-- Publish actual state, not the input intent (which may be refused).
AddEventHandler("open77:chat:requestVisibility", function()
    TriggerEvent("open77:chat:visibility", opened == true)
end)

-- Native Escape is swallowed before CEF sees it. Release this modal directly.
AddEventHandler("open77:pauseKey", closeChat)
AddEventHandler("open77:chat:open", openChat)
AddEventHandler("chat:open", openChat)
AddEventHandler("chat:close", closeChat)

exports("addMessage", addMessage)
exports("clear", function() send("chat:clear", {}) return true end)
exports("addSuggestion", function(command, help, parameters)
    send("chat:addSuggestion", {
        command = tostring(command or ""),
        help = tostring(help or ""),
        parameters = parameters or {}
    })
    return true
end)
exports("removeSuggestion", function(command)
    send("chat:removeSuggestion", { command = tostring(command or "") })
    return true
end)
exports("setEnabled", function(value)
    enabled = value ~= false
    if not enabled then closeChat() end
    send("chat:state", { enabled = enabled })
    return true
end)
exports("isEnabled", function() return enabled end)

AddEventHandler("onClientResourceStart", function(name)
    if name ~= GetCurrentResourceName() then return end
    local reason
    chat, reason = WebUI.create({
        entry = "web/index.html",
        layer = "hud",
        width = 1920,
        height = 1080,
        -- Maximum supported WebUI cadence. Chromium only produces a frame when
        -- the page is damaged, so an idle chat does not continuously repaint.
        fps = 240,
        zIndex = 700,
        transparent = true,
        visible = true
    })
    if not chat then
        print("Open77 chat WebUI failed: " .. tostring(reason))
        return
    end

    chat:on("chat:ready", function()
        send("chat:state", { enabled = enabled })
        addMessage({
            type = "system",
            author = "OPEN77",
            text = "Chat connected — press T to type",
            color = { 0, 229, 255 }
        })
        requestSuggestions()
        SetTimeout(1000, requestSuggestions)
    end)
    chat:on("chat:requestSuggestions", requestSuggestions)
    chat:on("chat:close", closeChat)
    chat:on("chat:submit", function(payload)
        local text = payload and tostring(payload.text or "") or ""
        if #text > 0 then
            local event, arguments = "chat:submit", { text }
            if text:sub(1, 1) == "/" then
                local tokens, parseError = commandTokens(text)
                if tokens == nil then
                    addMessage({
                        type = "error",
                        author = "COMMAND",
                        text = parseError,
                        color = { 255, 76, 92 }
                    })
                    return
                end
                event, arguments = "open77:command:execute", tokens
                TriggerEvent("chat:commandSubmitted", text, tokens)

                -- A8: client commands resolve first. `unknown_command` is the
                -- signal to forward, and is not an error; any other refusal is
                -- a real one and stops here rather than being sent to a server
                -- that would answer `unknown_command` a second time.
                if type(ExecuteCommand) == "function" then
                    local handled, reason = ExecuteCommand(text)
                    if handled then
                        closeChat()
                        return
                    end
                    if reason ~= nil and reason ~= "unknown_command" then
                        addMessage({
                            type = "error",
                            author = "COMMAND",
                            text = reason == "command_restricted"
                                and ("/" .. tokens[1] .. " is restricted and cannot run on the client.")
                                or ("Command refused: " .. tostring(reason)),
                            color = { 255, 76, 92 }
                        })
                        closeChat()
                        return
                    end
                end
            end

            local accepted, errorMessage = TriggerServerEvent(event, table.unpack(arguments))
            if not accepted then
                addMessage({
                    type = "error",
                    author = "NETWORK",
                    text = tostring(errorMessage or "Message could not be sent."),
                    color = { 255, 76, 92 }
                })
            end
        end
        closeChat()
    end)
end)

AddEventHandler("onClientResourceStop", function(name)
    if name ~= GetCurrentResourceName() then return end
    opened = false
    chat = nil
    TriggerEvent("open77:chat:visibility", false)
end)
