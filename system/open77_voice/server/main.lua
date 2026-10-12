-- Reference authoritative voice policy.
--
-- This package deliberately does not relay audio in Lua. Open77's native SFU
-- validates the authenticated sender, routing bucket, proximity and channel
-- membership, then fans out one bounded Opus frame. Lua owns gameplay policy.

AddEventHandler("onResourceStart", function(name)
    if name ~= GetCurrentResourceName() then return end
    local status, reason = Open77.voice.status()
    if not status then
        print("[open77_voice] status unavailable: " .. tostring(reason))
        return
    end
    print(("[open77_voice] enabled=%s quality=%s bitrate=%s proximity=%.1fm")
        :format(tostring(status.enabled), tostring(status.quality),
            tostring(status.bitrate), tonumber(status.defaultProximityDistance) or 0))
end)

-- Server packages call Open77.voice directly. The dedicated server runtime
-- deliberately has no client-style exports() global: channel ownership must
-- stay attached to the resource whose Lua VM performed the native call.

local playerPushToTalkKey = {}
local lastPushToTalkRequest = {}

local function normalizePushToTalkKey(value)
    if type(value) ~= "string" or #value > 12 then
        return nil, "unsupported_push_to_talk_key"
    end
    local key = value:upper():gsub("^%s+", ""):gsub("%s+$", "")
    if key:match("^[A-Z0-9]$") then return key end
    if key:match("^MOUSE[1-5]$") then return key end
    local functionNumber = tonumber(key:match("^F(%d%d?)$"))
    if functionNumber and functionNumber >= 1 and functionNumber <= 12 then return key end
    local supported = {
        SPACE = true, ENTER = true, RETURN = true, TAB = true, SHIFT = true,
        CTRL = true, CONTROL = true, ALT = true, CAPSLOCK = true,
        BACKSPACE = true, INSERT = true, DELETE = true, HOME = true, END = true,
        PAGEUP = true, PAGEDOWN = true, UP = true, DOWN = true,
        LEFT = true, RIGHT = true,
    }
    if supported[key] then return key end
    return nil, "unsupported_push_to_talk_key"
end

local function sendPushToTalkKey(player, key)
    return TriggerClientEvent("open77:voice:pushToTalkKeyApplied", player, key)
end

RegisterNetEvent("open77:voice:setPushToTalkKey", function(value)
    local player = tonumber(source)
    if not player or player <= 0 then return end
    local now = Open77.time.monotonic()
    if lastPushToTalkRequest[player] and now - lastPushToTalkRequest[player] < 0.10 then
        return
    end
    lastPushToTalkRequest[player] = now
    local key = normalizePushToTalkKey(value)
    if not key then return end
    playerPushToTalkKey[player] = key
    sendPushToTalkKey(player, key)
end)

RegisterNetEvent("open77:voice:requestPushToTalkKey", function()
    local player = tonumber(source)
    if not player or player <= 0 then return end
    sendPushToTalkKey(player, playerPushToTalkKey[player] or "N")
end)

AddEventHandler("playerDropped", function()
    playerPushToTalkKey[source] = nil
    lastPushToTalkRequest[source] = nil
end)
