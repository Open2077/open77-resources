local page
local pageReady = false
local visible = true
local visibilityRevision = 0
local configured = false
local cycleKey = "F11"
local modes = {}
local modeByName = {}
local current = { mode = "normal", label = "NORMAL", distance = 20.0, color = "#22D8E2" }
local errorText = ""
local errorUntil = 0
local lastPayload = ""

local function acceptModes(payload)
    if type(payload.modes) ~= "table" or #payload.modes < 1 or #payload.modes > 8 then
        return false
    end
    local parsed, byName = {}, {}
    for index, candidate in ipairs(payload.modes) do
        if type(candidate) ~= "table" then return false end
        local name = tostring(candidate.name or "")
        local distance = tonumber(candidate.distance)
        if #name < 1 or #name > 24 or not distance or distance < 0.5 or distance > 1000 then
            return false
        end
        parsed[index] = {
            name = name,
            label = tostring(candidate.label or name):sub(1, 32),
            distance = distance,
            color = tostring(candidate.color or "#22D8E2"),
        }
        byName[name] = parsed[index]
    end
    modes, modeByName = parsed, byName
    cycleKey = tostring(payload.cycleKey or "F11"):upper()
    configured = true
    return true
end

local function publish(status)
    if not page or not pageReady then return end
    status = status or {}
    local now = Open77.time.monotonic()
    if errorText ~= "" and now >= errorUntil then errorText = "" end
    local mode = modeByName[current.mode] or current
    local modeIndex = 1
    for index, candidate in ipairs(modes) do
        if candidate.name == current.mode then
            modeIndex = index
            break
        end
    end
    local modeCount = math.max(1, #modes)
    local inputLevel = tonumber(status.inputLevel or status.microphoneActivity) or 0
    inputLevel = math.max(0, math.min(1, inputLevel))
    -- Two decimals are enough for a twelve-segment HUD meter and avoid
    -- repainting the page for inaudible native capture noise.
    inputLevel = math.floor(inputLevel * 100 + 0.5) / 100
    local available = status.available == true
    local captureEnabled = status.captureEnabled == true
    local transmitting = status.transmitting == true
    local microphoneDetected = status.localTalking == true
    local state = "idle"
    if not configured or not available then
        state = "offline"
    elseif not captureEnabled then
        state = "muted"
    elseif transmitting then
        state = "talking"
    elseif microphoneDetected or inputLevel > 0.025 then
        state = "detected"
    end
    -- Send the level the twelve-segment meter can actually display. Keep the
    -- state decision above at its original threshold (voice activity is not
    -- quantized); sub-segment capture noise needs no new CEF frame.
    inputLevel = math.floor(inputLevel * 12 + 0.5) / 12
    local payload = {
        visible = visible,
        configured = configured,
        mode = tostring(mode.label or mode.name or "VOICE"),
        modeName = tostring(mode.name or current.mode or "normal"),
        distance = tonumber(current.distance or mode.distance) or 0,
        color = tostring(current.color or mode.color or "#22D8E2"),
        key = cycleKey,
        modeIndex = modeIndex,
        modeCount = modeCount,
        modes = modes,
        reachPercent = math.floor((modeIndex / modeCount) * 100 + 0.5),
        state = state,
        available = available,
        microphoneDetected = microphoneDetected,
        transmitting = transmitting,
        captureEnabled = captureEnabled,
        inputLevel = inputLevel,
        activation = status.voiceActivation == true and "vad" or "ptt",
        activeTalkers = math.max(0, tonumber(status.activeTalkers) or 0),
        captureState = tostring(status.captureState or "unavailable"),
        error = errorText,
    }
    local encoded = Open77.json.encode(payload) or ""
    if encoded == lastPayload then return end
    lastPayload = encoded
    page:send("open-voice:update", payload)
end

RegisterNetEvent("open-voice:state", function(payload)
    if type(payload) ~= "table" then return end
    if payload.modes and not acceptModes(payload) then
        errorText = "INVALID SERVER VOICE CONFIG"
        errorUntil = Open77.time.monotonic() + 5.0
        return
    end
    local mode = modeByName[tostring(payload.mode or "")]
    if mode then
        current = {
            mode = mode.name,
            label = tostring(payload.label or mode.label),
            distance = tonumber(payload.distance) or mode.distance,
            color = tostring(payload.color or mode.color),
        }
        TriggerEvent("open-voice:modeChanged", current.mode, current.distance,
            current.label, current.color)
    end
    publish(Open77.voice.status() or {})
end)

local function setHudVisible(value)
    visibilityRevision = visibilityRevision + 1
    local revision = visibilityRevision
    visible = value == true
    if page and visible then page:show() end
    lastPayload = ""
    publish(Open77.voice.status() or {})
    if not visible and page then
        local target = page
        CreateThread(function()
            Wait(220) -- Let the existing 200 ms fade finish before suspending CEF.
            if page == target and not visible and revision == visibilityRevision then target:hide() end
        end)
    end
end
AddEventHandler("open-voice:setHudVisible", setHudVisible)

RegisterNetEvent("open-voice:error", function(reason)
    errorText = tostring(reason or "VOICE REQUEST REJECTED"):upper():sub(1, 80)
    errorUntil = Open77.time.monotonic() + 3.5
    publish(Open77.voice.status() or {})
end)

local function requestCycle()
    if not configured then return false, "voice_modes_not_ready" end
    local sent, reason = TriggerServerEvent("open-voice:cycle")
    if sent ~= true then
        errorText = tostring(reason or "cycle_request_failed"):upper():sub(1, 80)
        errorUntil = Open77.time.monotonic() + 3.5
        publish(Open77.voice.status() or {})
        return false, reason
    end
    return true
end

AddEventHandler("open-voice:cycle", function()
    requestCycle()
end)

AddEventHandler("onClientResourceStart", function(name)
    if name ~= GetCurrentResourceName() then return end
    local reason
    page, reason = WebUI.create({
        entry = "web/index.html",
        layer = "hud",
        width = 1920,
        height = 1080,
        -- Full logical layout, but only this padded bottom-right rectangle is
        -- composited over the game. Includes long mode labels, errors/shadows.
        drawBounds = { x = -768, y = -160, width = 768, height = 160 },
        fps = 60,
        zIndex = 760,
        transparent = true,
        visible = true,
    })
    if not page then
        print("[open-voice] HUD unavailable: " .. tostring(reason))
    else
        page:on("open-voice:ready", function()
            pageReady = true
            lastPayload = ""
            publish(Open77.voice.status() or {})
        end)
    end

    CreateThread(function()
        while true do
            local sent, sendReason = TriggerServerEvent("open-voice:ready")
            if sent ~= true then
                errorText = tostring(sendReason or "VOICE SERVER NOT READY"):upper():sub(1, 80)
                errorUntil = Open77.time.monotonic() + 2.5
            end
            if configured then return end
            Wait(2000)
        end
    end)

    CreateThread(function()
        local wasDown = false
        while true do
            local down = false
            if configured and not Open77.input.isCaptured() then
                down = Open77.input.isDown(cycleKey) == true
            end
            if down and not wasDown then requestCycle() end
            wasDown = down
            Wait(10)
        end
    end)

    CreateThread(function()
        while true do
            if visible then
                local status = Open77.voice.status()
                if status then publish(status) end
            end
            Wait(50)
        end
    end)
end)

AddEventHandler("onClientResourceStop", function(name)
    if name ~= GetCurrentResourceName() then return end
    page, pageReady = nil, false
end)

exports("getState", function()
    return {
        configured = configured,
        mode = current.mode,
        label = current.label,
        distance = current.distance,
        color = current.color,
        cycleKey = cycleKey,
        visible = visible,
    }
end)
exports("getModes", function()
    local result = {}
    for index, mode in ipairs(modes) do
        result[index] = {
            name = mode.name, label = mode.label,
            distance = mode.distance, color = mode.color,
        }
    end
    return result
end)
exports("requestCycle", requestCycle)
exports("setHudVisible", function(value)
    setHudVisible(value)
    return true
end)
