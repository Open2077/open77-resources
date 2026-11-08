-- A player preference owned by the system pause menu, never by a server page.
-- The native host applies it after browser decoding, including iframe audio.
PauseWebAudio = {}
local key = "audio.webui.volume"
local function available()
    return Open77.webui and type(Open77.webui.getVolume) == "function" and
        type(Open77.webui.setVolume) == "function"
end
local function valid(value)
    return type(value) == "number" and value == value and value >= 0 and
        value <= 100 and value == math.floor(value)
end

function PauseWebAudio.restore()
    if not available() then return false, "webui_audio_backend_unavailable" end
    local value, reason = Open77.kvp.get(key, 100)
    if value == nil then return false, reason end
    if not valid(value) then value = 100 end
    return Open77.webui.setVolume(value)
end

function PauseWebAudio.section()
    if not available() then return nil end
    local value = Open77.webui.getVolume()
    if not valid(value) then return nil end
    return { group = "webui_audio", title = "webAudio", entries = {
        { name = "WebUiVolume", label = PauseStrings.webAudio.volume,
          type = "int", value = value, min = 0, max = 100, step = 1, suffix = "%" },
        { name = "WebUiAudioScope", label = PauseStrings.webAudio.scope,
          type = "info", value = PauseStrings.webAudio.hint },
    } }
end

function PauseWebAudio.set(payload)
    if not available() then return false, "webui_audio_backend_unavailable" end
    if payload.name ~= "WebUiVolume" or not valid(payload.value) then
        return false, "invalid_audio_volume"
    end
    local previous = Open77.webui.getVolume()
    local ok, reason = Open77.webui.setVolume(payload.value)
    if not ok then return false, reason end
    local saved, saveReason = Open77.kvp.set(key, payload.value)
    if not saved then
        if valid(previous) then Open77.webui.setVolume(previous) end
        return false, saveReason or "preference_not_saved"
    end
    return true
end
