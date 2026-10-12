local enabled = true
local MAX_MESSAGE_BYTES = 256
local readyRequests = {}

local CHAT_SUGGESTIONS = {
    {
        command = "/help",
        help = "Show chat and command help.",
        parameters = {}
    },
    {
        command = "/clear",
        help = "Clear your local chat history.",
        parameters = {}
    },
    {
        command = "/id",
        help = "Show your temporary session player ID.",
        parameters = {}
    },
}

local function clean(text)
    text = tostring(text or ""):gsub("[%c]", " ")
    text = text:match("^%s*(.-)%s*$") or ""
    if #text > MAX_MESSAGE_BYTES then
        local ok, boundary = pcall(utf8.offset, text, 0, MAX_MESSAGE_BYTES + 1)
        if ok and boundary then text = text:sub(1, boundary - 1)
        else text = text:sub(1, MAX_MESSAGE_BYTES) end
    end
    return text
end

local function targetId(value)
    local target = tonumber(value)
    return (target == nil or target == 0) and -1 or target
end

local function push(target, message)
    if type(message) == "string" then message = { text = message } end
    if type(message) ~= "table" then return false end
    return TriggerClientEvent("chat:addMessage", targetId(target), message)
end

RegisterNetEvent("chat:submit", function(raw)
    if not enabled then return end
    local text = clean(raw)
    if text == "" then return end

    local player = source
    local name = GetPlayerName(player) or ("Player " .. tostring(player))

    -- FiveM-compatible veto point. `chatMessage` is host-wide and cancellable: any
    -- resource can AddEventHandler("chatMessage", ...) and call CancelEvent() to
    -- drop the message before a single client sees it. Read `player` and `name`
    -- before awaiting -- the global `source` belongs to whatever task runs next.
    local verdict = TriggerCancellableEvent("chatMessage", player, name, text)
    if verdict ~= nil and verdict:await() then return end

    -- Accepted. Announced host-wide so logging, RP and moderation resources can
    -- observe it without subscribing to `chat:submit` themselves.
    TriggerEvent("chat:message", player, name, text)
    push(-1, {
        type = "player",
        author = name,
        text = text,
        playerId = tostring(player),
        color = { 238, 244, 248 }
    })
end)

-- The WebUI requests suggestions whenever it is created. Other resources may
-- listen to the same network event and send their own command metadata directly
-- to this authenticated player.
RegisterNetEvent("chat:ready", function()
    local player = source
    local now = Open77.time.monotonic()
    if readyRequests[player] ~= nil and now - readyRequests[player] < 1 then return end
    readyRequests[player] = now
    TriggerClientEvent("chat:addSuggestions", player, CHAT_SUGGESTIONS)
end)

RegisterCommand("help", function(player)
    push(player, {
        type = "system",
        author = "COMMANDS",
        text = "Type / to browse available commands. Use the arrow keys to select a suggestion and Tab to complete it.",
        color = { 0, 229, 255 }
    })
end, false)

RegisterCommand("clear", function(player)
    TriggerClientEvent("chat:clear", player)
end, false)

RegisterCommand("id", function(player)
    if player == nil or player <= 0 then
        print("id is only available to an authenticated player in chat")
        return
    end
    push(player, {
        type = "system",
        author = "SESSION",
        text = "Your session ID is " .. tostring(player) .. ".",
        color = { 0, 229, 255 }
    })
end, false)

-- Server-side API for other resources.
AddEventHandler("chat:addMessage", function(target, message) push(target, message) end)
AddEventHandler("chat:broadcast", function(message) push(-1, message) end)
AddEventHandler("chat:clear", function(target)
    TriggerClientEvent("chat:clear", targetId(target))
end)
AddEventHandler("chat:setEnabled", function(value, target)
    TriggerClientEvent("chat:setEnabled", targetId(target), value ~= false)
end)
AddEventHandler("chat:setServerEnabled", function(value)
    enabled = value ~= false
end)
AddEventHandler("chat:addSuggestion", function(target, command, help, parameters)
    TriggerClientEvent("chat:addSuggestion", targetId(target),
        tostring(command or ""), tostring(help or ""), parameters or {})
end)
AddEventHandler("chat:addSuggestions", function(target, suggestions)
    TriggerClientEvent("chat:addSuggestions", targetId(target), suggestions or {})
end)
AddEventHandler("chat:removeSuggestion", function(target, command)
    TriggerClientEvent("chat:removeSuggestion", targetId(target), tostring(command or ""))
end)
