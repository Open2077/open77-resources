-- Reference client policy. Capture/Opus/jitter/spatial audio stay native; this
-- loop only publishes a bounded PTT intent and mirrors talking state to the
-- native nameplate renderer.

local transmitting = false
local transmitRejectedWhileHeld = false
local knownTalkers = {}
local proximityMode = "normal"
local requestedProximityMode = nil
local pushToTalkKey = tostring(VoiceConfig.pushToTalkKey or "N"):upper()

local function normalizePushToTalkKey(value)
    local key = tostring(value or ""):upper():gsub("^%s+", ""):gsub("%s+$", "")
    if key:match("^[A-Z0-9]$") then return key end
    if key:match("^MOUSE[1-5]$") then return key end
    local functionNumber = tonumber(key:match("^F(%d%d?)$"))
    if functionNumber and functionNumber >= 1 and functionNumber <= 12 then return key end
    local supported = {
        SPACE = true, ENTER = true, RETURN = true, TAB = true, SHIFT = true, CTRL = true,
        CONTROL = true, ALT = true, CAPSLOCK = true, BACKSPACE = true, INSERT = true,
        DELETE = true, HOME = true, END = true, PAGEUP = true,
        PAGEDOWN = true, UP = true, DOWN = true, LEFT = true, RIGHT = true,
    }
    if supported[key] then return key end
    return nil, "unsupported_push_to_talk_key"
end

local function setPushToTalkKey(value)
    local key, reason = normalizePushToTalkKey(value)
    if not key then return false, reason end
    if transmitting then
        Open77.voice.setTransmitting(false, VoiceConfig.transmitIntent)
        transmitting = false
        transmitRejectedWhileHeld = false
    end
    pushToTalkKey = key
    TriggerEvent("open77:voice:pushToTalkKeyChanged", key)
    return true, key
end

AddEventHandler("open77:voice:setPushToTalkKey", function(value)
    local ok, reason = setPushToTalkKey(value)
    if not ok then
        print("[open77_voice] rejected PTT key: " .. tostring(reason))
    end
end)

RegisterNetEvent("open77:voice:pushToTalkKeyApplied", function(value)
    local ok, reason = setPushToTalkKey(value)
    if not ok then
        print("[open77_voice] rejected server PTT key: " .. tostring(reason))
    end
end)

local function voiceStatus()
    local status, reason = Open77.voice.status()
    if not status then return nil, reason end
    return status
end

local function configuredMode(name)
    name = tostring(name or ""):lower()
    for _, candidate in ipairs(VoiceConfig.proximityModeOrder or {}) do
        if tostring(candidate):lower() == name then return name end
    end
    return nil
end

local function distanceForMode(name, status)
    name = configuredMode(name)
    if not name then return nil, "unknown_proximity_mode" end
    status = status or voiceStatus()
    if not status then return nil, "voice_backend_unavailable" end
    local configured = VoiceConfig.proximityModes and VoiceConfig.proximityModes[name]
    local distance = tonumber(configured)
    if not distance and name == "normal" then
        distance = tonumber(status.defaultProximityDistance)
    end
    if not distance then return nil, "invalid_proximity_mode_distance" end
    return distance
end

local function modeForDistance(distance, status)
    status = status or voiceStatus()
    distance = tonumber(distance)
    if not status or not distance then return "custom" end
    for _, name in ipairs(VoiceConfig.proximityModeOrder or {}) do
        local expected = distanceForMode(name, status)
        if expected and math.abs(expected - distance) < 0.01 then return name end
    end
    return "custom"
end

local function notifyProximityMode(name, distance)
    -- Optional and deliberately quiet: one replaceable 1.6 s toast, only for
    -- an explicit preset change. The native API has no UI side effect.
    local promise = Open77.exports.call("open77_notifications", "show", {
        id = "voice_proximity_mode",
        replace = true,
        type = "info",
        title = "VOICE",
        message = ("%s · %.0f m"):format(tostring(name):upper(), tonumber(distance) or 0),
        position = "middle_left",
        durationMs = 1600,
        progress = false,
    })
    -- No hard dependency: a server may replace the notification package.
    -- Ignoring the promise is intentional; the mode request remains valid.
    return promise ~= nil
end

local function setProximityDistance(distance)
    distance = tonumber(distance)
    if not distance then return false, "invalid_proximity_distance" end
    local ok, reason = Open77.voice.setProximityDistance(distance)
    if ok then
        requestedProximityMode = modeForDistance(distance)
        TriggerEvent("open77:voice:proximityRequested", distance, requestedProximityMode)
    end
    return ok, reason
end


local function setProximityMode(name, notify)
    name = configuredMode(name)
    if not name then return false, "unknown_proximity_mode" end
    local status, statusError = voiceStatus()
    if not status then return false, statusError end
    local distance, reason = distanceForMode(name, status)
    if not distance then return false, reason end
    local ok, requestError = Open77.voice.setProximityDistance(distance)
    if not ok then return false, requestError end
    requestedProximityMode = name
    TriggerEvent("open77:voice:proximityRequested", distance, name)
    if notify ~= false then notifyProximityMode(name, distance) end
    return true
end

local function getProximityMode()
    local status, reason = voiceStatus()
    if not status then return nil, reason end
    local distance = tonumber(status.proximityDistance) or
        tonumber(status.defaultProximityDistance) or 20.0
    return modeForDistance(distance, status), distance
end

local function cycleProximityMode(notify)
    local order = VoiceConfig.proximityModeOrder or {}
    if #order == 0 then return false, "no_proximity_modes" end
    local current = requestedProximityMode or getProximityMode()
    local index = 0
    for candidateIndex, name in ipairs(order) do
        if tostring(name):lower() == tostring(current):lower() then index = candidateIndex end
    end
    local nextName = order[index % #order + 1]
    return setProximityMode(nextName, notify)
end

local function applyTalking(playerId, talking, level, detail, emit)
    playerId = tonumber(playerId) or 0
    if playerId <= 0 then return end
    talking = talking == true
    if knownTalkers[playerId] == talking then return end
    knownTalkers[playerId] = talking
    Open77.nameplates.setTalking(playerId, talking)
    if emit then
        TriggerEvent("open77:voice:talkingChanged", playerId, talking,
            tonumber(level) or 0.0, tostring(detail or ""))
    end
end

-- Native voice events arrive on the Lua host thread. The same event is public
-- to other voice-capable packages (HUD, subtitles, moderation UI, etc.).
AddEventHandler("open77:voice:talkingChanged", function(playerId, talking, level, detail)
    applyTalking(playerId, talking, level, detail, false)
end)

local function clearTalking(playerId)
    playerId = tonumber(playerId) or 0
    if playerId <= 0 then return end
    knownTalkers[playerId] = nil
    Open77.nameplates.setTalking(playerId, false)
end

AddEventHandler("open77:voice:participantRemoved", clearTalking)
AddEventHandler("open77:voice:sessionReset", function()
    for playerId in pairs(knownTalkers) do clearTalking(playerId) end
    proximityMode = "normal"
    requestedProximityMode = nil
end)

AddEventHandler("open77:voice:proximityChanged", function(playerId, enabled, _, detail)
    local distance = tonumber(detail)
    if not distance then return end
    local status = voiceStatus()
    proximityMode = modeForDistance(distance, status)
    requestedProximityMode = nil
    TriggerEvent("open77:voice:proximityModeChanged", proximityMode, distance,
        enabled == true)
end)

AddEventHandler("onClientResourceStart", function(name)
    if name ~= GetCurrentResourceName() then return end
    -- Older clients may not expose facial presentation yet; voice keeps working.
    if Open77.voice.setLipSyncEnabled then
        local ok, reason = Open77.voice.setLipSyncEnabled(VoiceConfig.lipSyncEnabled ~= false)
        if not ok then print("[open77_voice] lipsync policy unavailable: " .. tostring(reason)) end
    end
    local requested, requestError = TriggerServerEvent("open77:voice:requestPushToTalkKey")
    if requested ~= true then
        print("[open77_voice] PTT key sync unavailable: " .. tostring(requestError))
    end
    -- The pause resource owns the per-server device/capture preference and
    -- restores it from KVP. Do not overwrite a player's disabled microphone
    -- merely because this gameplay policy resource started afterwards.
    -- Resolve the selector now as well as on PTT down. VAD can then be enabled
    -- from the pause menu before the player has pressed the key once.
    local intentOk, intentError = Open77.voice.setTransmitting(
        false, VoiceConfig.transmitIntent)
    if not intentOk then
        print("[open77_voice] transmit intent unavailable: " .. tostring(intentError))
    end

    -- PTT is sampled through the native action-key surface, not WebUI. When a
    -- menu captures input the request is released immediately; the server
    -- still validates every scope and recipient.
    CreateThread(function()
        while true do
            local down = VoiceConfig.enabled and not Open77.input.isCaptured() and
                Open77.input.isDown(pushToTalkKey)
            if not down then transmitRejectedWhileHeld = false end
            if down ~= transmitting and not (down and transmitRejectedWhileHeld) then
                transmitting = down
                local changed, transmitError = Open77.voice.setTransmitting(
                    down, VoiceConfig.transmitIntent)
                if not changed then
                    transmitting = false
                    transmitRejectedWhileHeld = down
                    print("[open77_voice] PTT failed: " .. tostring(transmitError))
                end
            end
            Wait(VoiceConfig.pollMilliseconds)
        end
    end)

    -- Opt-in example binding. It uses a press edge and releases while WebUI
    -- captures input, rather than firing every frame. Disabled by default.
    if VoiceConfig.cycleProximityKey and VoiceConfig.cycleProximityKey ~= "" then
        CreateThread(function()
            local wasDown = false
            while true do
                local down = not Open77.input.isCaptured() and
                    Open77.input.isDown(VoiceConfig.cycleProximityKey)
                if down and not wasDown then
                    local ok, cycleError = cycleProximityMode(true)
                    if not ok then
                        print("[open77_voice] proximity cycle failed: " .. tostring(cycleError))
                    end
                end
                wasDown = down
                Wait(VoiceConfig.pollMilliseconds)
            end
        end)
    end

    -- Events are the fast path; this snapshot is the recovery path for late
    -- joins, device restarts and a dropped UI event. It never touches audio.
    CreateThread(function()
        while true do
            local seen = {}
            local talkers = Open77.voice.talkers()
            if talkers then
                for _, talker in ipairs(talkers) do
                    local id = tonumber(talker.playerId) or 0
                    if id > 0 then
                        seen[id] = true
                        applyTalking(id, talker.talking == true,
                            talker.level, "snapshot", true)
                    end
                end
            end
            for id, talking in pairs(knownTalkers) do
                if talking and not seen[id] then applyTalking(id, false, 0.0, "left", true) end
            end
            Wait(VoiceConfig.talkerPollMilliseconds)
        end
    end)
end)

AddEventHandler("onClientResourceStop", function(name)
    if name ~= GetCurrentResourceName() then return end
    if transmitting then Open77.voice.setTransmitting(false, VoiceConfig.transmitIntent) end
    Open77.voice.setMicrophoneTest(false)
    for playerId in pairs(knownTalkers) do Open77.nameplates.setTalking(playerId, false) end
end)

exports("status", function() return Open77.voice.status() end)
exports("getPushToTalkKey", function() return pushToTalkKey end)
exports("setPushToTalkKey", setPushToTalkKey)
exports("devices", function(flow) return Open77.voice.devices(flow or "all") end)
exports("getProximityDistance", function()
    local status, reason = voiceStatus()
    if not status then return nil, reason end
    return status.proximityDistance, status
end)
exports("setProximityDistance", setProximityDistance)
exports("getProximityMode", getProximityMode)
exports("setProximityMode", setProximityMode)
exports("cycleProximityMode", cycleProximityMode)
exports("setPlayerVolume", function(playerId, volume)
    return Open77.voice.setPlayerVolume(playerId, volume)
end)
exports("setPlayerBlocked", function(playerId, blocked)
    return Open77.voice.setPlayerBlocked(playerId, blocked)
end)
exports("setChannelVolume", function(channelId, volume)
    return Open77.voice.setChannelVolume(tostring(channelId), volume)
end)
