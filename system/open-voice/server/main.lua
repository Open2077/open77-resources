-- pma-voice-inspired reach policy. Audio never crosses Lua: the native
-- open77_voice stack remains the sole capture/Opus/SFU/PTT implementation.

local raw = OpenVoiceServerConfig or {}
local modes = {}
local modeByName = {}
local defaultIndex
local playerMode = {}
local lastRequest = {}
local lastReady = {}
local revision = 0

local function finite(value)
    return type(value) == "number" and value == value and
        value > -math.huge and value < math.huge
end

local function validKey(value)
    if type(value) ~= "string" or #value == 0 or #value > 12 then return false end
    value = value:upper()
    if value:match("^[A-Z0-9]$") then return true end
    local number = tonumber(value:match("^F(%d%d?)$"))
    if number and number >= 1 and number <= 12 and value == "F" .. tostring(number) then
        return true
    end
    return value == "SPACE" or value == "ENTER" or value == "RETURN" or
        value == "UP" or value == "DOWN" or value == "LEFT" or value == "RIGHT"
end

local function validColor(value)
    return type(value) == "string" and
        value:match("^#[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]$") ~= nil
end

local function fail(reason)
    error("[open-voice] invalid server config: " .. tostring(reason), 0)
end

if type(raw.modes) ~= "table" or #raw.modes < 1 or #raw.modes > 8 then
    fail("modes must contain 1..8 entries")
end
for index, candidate in ipairs(raw.modes) do
    if type(candidate) ~= "table" then fail("mode " .. index .. " must be a table") end
    local name = tostring(candidate.name or ""):lower()
    local label = tostring(candidate.label or "")
    local distance = candidate.distance
    if #name < 1 or #name > 24 or not name:match("^[a-z][a-z0-9_-]*$") then
        fail("mode " .. index .. " has an invalid name")
    end
    if modeByName[name] then fail("duplicate mode " .. name) end
    if #label < 1 or #label > 32 or label:find("[%c]") then
        fail("mode " .. name .. " has an invalid label")
    end
    if not finite(distance) or distance < 0.5 or distance > 1000.0 then
        fail("mode " .. name .. " distance must be 0.5..1000")
    end
    local color = candidate.color or "#22D8E2"
    if not validColor(color) then fail("mode " .. name .. " has an invalid color") end
    local mode = {
        name = name,
        label = label,
        distance = distance,
        color = color:upper(),
        index = index,
    }
    modes[index] = mode
    modeByName[name] = mode
end

local defaultName = tostring(raw.defaultMode or "normal"):lower()
if not modeByName[defaultName] then fail("defaultMode does not name a configured mode") end
defaultIndex = modeByName[defaultName].index

local cycleKey = tostring(raw.cycleKey or "F11"):upper()
if not validKey(cycleKey) then fail("cycleKey is not supported by Open77.input") end
local cooldown = raw.requestCooldownSeconds or 0.25
if not finite(cooldown) or cooldown < 0.1 or cooldown > 5.0 then
    fail("requestCooldownSeconds must be 0.1..5.0")
end

local function clientModes()
    local result = {}
    for index, mode in ipairs(modes) do
        result[index] = {
            name = mode.name,
            label = mode.label,
            distance = mode.distance,
            color = mode.color,
        }
    end
    return result
end

local function sendError(player, reason)
    TriggerClientEvent("open-voice:error", player, tostring(reason or "request_rejected"))
end

local function applyMode(player, index, includeConfig)
    local mode = modes[index]
    if not mode then return false, "mode_not_found" end
    local ok, reason = Open77.voice.setProximity(player, {
        enabled = true,
        distance = mode.distance,
    })
    if not ok then return false, reason end
    playerMode[player] = index
    revision = revision + 1
    local payload = {
        revision = revision,
        mode = mode.name,
        label = mode.label,
        distance = mode.distance,
        color = mode.color,
    }
    if includeConfig then
        payload.cycleKey = cycleKey
        payload.defaultMode = defaultName
        payload.modes = clientModes()
    end
    TriggerEvent("open-voice:modeApplied", player, mode.name, mode.distance,
        mode.label, mode.color)
    local sent, sendReason = TriggerClientEvent("open-voice:state", player, payload)
    return sent == true, sendReason
end

-- Trusted server resources can drive the same policy without exposing an
-- arbitrary-distance network event to clients.
AddEventHandler("open-voice:setPlayerMode", function(player, modeName)
    player = tonumber(player)
    local mode = modeByName[tostring(modeName or ""):lower()]
    if not player or player <= 0 or not mode then return end
    local ok, reason = applyMode(player, mode.index, false)
    if not ok then sendError(player, reason) end
end)

AddEventHandler("open-voice:cyclePlayerMode", function(player)
    player = tonumber(player)
    if not player or player <= 0 then return end
    local current = playerMode[player] or defaultIndex
    local ok, reason = applyMode(player, current % #modes + 1, false)
    if not ok then sendError(player, reason) end
end)

RegisterNetEvent("open-voice:ready", function()
    local player = tonumber(source)
    if not player or player <= 0 then return end
    local now = Open77.time.monotonic()
    if lastReady[player] and now - lastReady[player] < 1.0 then return end
    lastReady[player] = now
    local index = playerMode[player] or defaultIndex
    local ok, reason = applyMode(player, index, true)
    if not ok then sendError(player, reason) end
end)

RegisterNetEvent("open-voice:cycle", function()
    local player = tonumber(source)
    if not player or player <= 0 then return end
    local now = Open77.time.monotonic()
    if lastRequest[player] and now - lastRequest[player] < cooldown then return end
    lastRequest[player] = now
    local current = playerMode[player] or defaultIndex
    local nextIndex = current % #modes + 1
    local ok, reason = applyMode(player, nextIndex, false)
    if not ok then sendError(player, reason) end
end)

AddEventHandler("playerDropped", function()
    playerMode[source] = nil
    lastRequest[source] = nil
    lastReady[source] = nil
end)

AddEventHandler("onResourceStart", function(name)
    if name ~= GetCurrentResourceName() then return end
    print(("[open-voice] ready modes=%d default=%s key=%s cooldown=%.2fs")
        :format(#modes, defaultName, cycleKey, cooldown))
end)
