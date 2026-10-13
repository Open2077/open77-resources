-- Open77 pause menu.
--
-- Escape never reaches the game any more: it is swallowed in the window
-- procedure, before the engine learns the key was pressed, which is the only
-- interception point that does not leave the blur and the world freeze behind.
-- The plugin forwards the press as `open77:pauseKey`, and this owns what happens
-- next.
--
-- The world keeps running while this is open. That is the entire reason the menu
-- exists rather than the vanilla one, so nothing here pauses anything.

local menu
AddEventHandler("open77:privacy:state", function(payload)
    if menu then menu:send("privacy:state", payload) end
end)
local open = false
local menuGeneration = 0
local mapRequest
local brandingRevision

local function publishBranding(force)
    if not menu then return end
    local appearance = Open77.pauseMenu.getAppearance(force and -1 or brandingRevision)
    if not appearance then return end
    -- Preserve the normal WebUI per-string quota even for a 1 MiB packaged logo.
    local chunks = {}
    for index = 1, #appearance.logo, 48000 do
        chunks[#chunks + 1] = appearance.logo:sub(index, index + 47999)
    end
    local sent = menu:send("pause:branding", {
        accentColor = appearance.accentColor, logoChunks = chunks
    })
    if sent then brandingRevision = appearance.revision end
end

-- The one string table, from shared/strings.lua (loaded first, see the
-- manifest). Held in a local so a typo is a nil index here rather than a
-- silently blank label on screen.
local S = PauseStrings

-- `{name}` substitution, the same grammar the page's i18n helper uses. A
-- placeholder with no value is left standing rather than blanked, so a missing
-- value is visible instead of merely wrong.
local function fmt(template, values)
    return (tostring(template):gsub("{(%w+)}", function(key)
        local value = values and values[key]
        if value == nil then return "{" .. key .. "}" end
        return tostring(value)
    end))
end

-- The native launcher context also exposes the DLL's protocol/build constants,
-- including masterless sessions; a Lua literal would drift after a wire bump.
local CLIENT_PROFILE = Open77.session.launcherContext() or {}

-- Settings categories, in display order.
--
-- Each tab names the engine groups it renders, in order, with the key of its
-- section heading in `PauseStrings.groups`. Groups are read with the bridge's
-- `settings.vars` and never invented (see docs/research/settings-api.md for the
-- tree survey). The page renders whatever arrives: the engine reports each
-- variable's localised label, type, value, bounds, list options and update
-- policy itself.
--
-- WHY THIS LIST IS THE FIX. Every tab used to name exactly ONE group, and for
-- video that meant `/video/display` plus `/graphics/basic` -- 18 variables out
-- of the ~90 the engine publishes under video and graphics. Everything a player
-- turns down to gain frames lived in the four groups nobody asked for:
--
--   /graphics/advanced    shadows (five separate controls), volumetric fog and
--                         clouds, screen space reflections, ambient occlusion,
--                         subsurface scattering, decals, mirrors, LOD preset,
--                         anisotropy, colour precision
--   /graphics/presets     texture quality, resolution scaling, DLSS / FSR2 /
--                         FSR3 / FSR4 / XeSS and their sharpness, frame
--                         generation, dynamic resolution bounds
--   /graphics/raytracing  the RT master switch and its five sub-options
--   /graphics/performance crowd density
--
-- Read against the engine's own declarations in
-- `r6/config/settings/options.json` and `.../platform/pc/options.json`, which
-- is where the group paths and each variable's type come from. Those two files
-- under-report -- `/audio/volume` is entirely absent from them yet answers at
-- runtime -- so they bound the list from below, never from above. Enumerating a
-- group is always the truth; this table only decides which groups appear where.
--
-- `enabled = false` shows a category without making it selectable, which is
-- how a planned tab announces itself without pretending to work.
local TABS = {
    -- What the screen does, and how much of it gets drawn at all.
    { id = "video", enabled = true, groups = {
        { path = "/video/display",    title = "display" },
        { path = "/brightness",       title = "brightness" },
        { path = "/graphics/presets", title = "upscaling" }
    } },
    -- What each drawn pixel costs. This is the tab that answers "I need frames".
    { id = "graphics", enabled = true, groups = {
        { path = "/graphics/basic",       title = "effects" },
        { path = "/graphics/advanced",    title = "quality" },
        { path = "/graphics/raytracing",  title = "raytracing" },
        { path = "/graphics/performance", title = "crowds" },
        { path = "/utilities",            title = "system" }
    } },
    { id = "audio", enabled = true, groups = {
        { path = "/audio/volume",       title = "volume" },
        { path = "/audio/misc",         title = "audioMisc" },
        { path = "/audio/dynamicrange", title = "audioRange" }
    } },
    { id = "voice", enabled = true, groups = {}, voice = true },
    { id = "controls", enabled = true, groups = {
        { path = "/controls",                 title = "controlsGeneral" },
        { path = "/controls/fppcameramouse",  title = "mouse" },
        { path = "/controls/tppcameramouse",  title = "mouseTpp" },
        { path = "/controls/vehicle",         title = "vehicle" },
        { path = "/controls/controller",      title = "pad" },
        { path = "/controls/fppcamerapad",    title = "padCamera" },
        { path = "/controls/tppcamerapad",    title = "padCameraTpp" }
    } },
    -- Not an engine group: rows come from the engine's RegisterKeyMapping
    -- registry (Open77.input.mappings), one keybind control per registered
    -- action. Rebinding writes back through Open77.input.rebind / reset.
    { id = "keybinds", enabled = true, groups = {}, keybinds = true },
    { id = "gameplay", enabled = true, groups = {
        { path = "/gameplay/misc",        title = "gameplayMisc" },
        { path = "/gameplay/difficulty",  title = "difficulty" },
        { path = "/gameplay/hud",         title = "hud" },
        { path = "/gameplay/performance", title = "performance" },
        { path = "/interface",            title = "interface" },
        { path = "/interface/hud",        title = "hudElements" }
    } }
}

local function tabByName(id)
    for _, tab in ipairs(TABS) do
        if tab.id == id then return tab end
    end
    return TABS[1]
end

-- ---------------------------------------------------------------------------
-- Session snapshot
--
-- The single source of truth is the native session (`Open77.network.status`).
-- The server's *name* is not part of the wire session, so it is resolved from
-- the last master catalog the client fetched -- the same data the browser
-- listed the server from. An endpoint that is not in the catalog (bare
-- autoconnect) falls back to showing the endpoint itself.
local catalogCache = { generation = -1, byEndpoint = {} }

local function catalogServer(endpoint)
    if not endpoint or endpoint == "" then return nil end
    local snapshot = Open77.network.catalog()
    if snapshot and snapshot.phase == "ready" and
        snapshot.generation ~= catalogCache.generation then
        catalogCache.generation = snapshot.generation
        catalogCache.byEndpoint = {}
        local page = Open77.json.decode(snapshot.body or "")
        for _, item in ipairs(page and page.items or {}) do
            local target = tostring(item.connectEndpoint or "")
            if target ~= "" then catalogCache.byEndpoint[target] = item end
        end
    end
    return catalogCache.byEndpoint[endpoint]
end

local function publishState()
    if not menu then return end
    publishBranding(false)

    local state = {
        client = {
            version = Open77.runtime.version(),
            protocolMajor = CLIENT_PROFILE.protocolMajor,
            protocolMinor = CLIENT_PROFILE.protocolMinor,
            gameBuild = CLIENT_PROFILE.gameBuild
        },
        connected = false,
        phase = "offline"
    }

    local status = Open77.network.status()
    if status then
        state.phase = tostring(status.phase or "offline")
        state.connected = state.phase == "active"
        state.endpoint = tostring(status.endpoint or "")
        state.player = tostring(status.playerName or "")
        state.playerId = tonumber(status.playerId) or 0
        state.ping = tonumber(status.ping) or 0
        state.tickRate = tonumber(status.serverTickRate) or 0
        state.snapshotRate = tonumber(status.snapshotRate) or 0

        local item = catalogServer(state.endpoint)
        if item then
            state.server = tostring(item.name or "")
            state.players = tonumber(item.connectedPlayers)
            state.capacity = tonumber(item.maximumPlayers)
            state.serverVersion = tostring(item.serverVersion or "")
            state.serverBuild = tonumber(item.expectedGameBuild)
            if item.protocol then
                state.serverProtocol = {
                    major = tonumber(item.protocol.major),
                    minor = tonumber(item.protocol.minor)
                }
            end
        end
    end

    -- No population figure is shown while in session, and that is deliberate.
    -- The only number available here is `connectedPlayers` from the server
    -- browser's catalogue, a snapshot taken when the browser listed servers --
    -- so it predates this player's own join and read `PLAYERS 0 / 10` to
    -- someone demonstrably in the session (measured 2026-09-01). A stale count
    -- presented as live is worse than no count: the panel exists to tell a
    -- player what their session actually is.
    --
    -- A live figure needs a source, and there is none reachable from here. The
    -- server knows it (`_sessions.AuthenticatedCount`, published to the master)
    -- but the session snapshot does not carry it, so surfacing it means a new
    -- wire field. Routing it through a server-side half of this resource was
    -- built and measured on 2026-09-01: the client's `TriggerServerEvent`
    -- arrives, and `TriggerClientEvent` back reports `sent=true` and never
    -- lands, because this resource runs from the client's BOOTSTRAP set -- it
    -- has to, the pause menu predates any connection -- and the server routes
    -- client events to the resource set it served. Client to server works,
    -- server to client does not reach a bootstrap resource.
    --
    -- So the row waits for a protocol field, and until then says nothing rather
    -- than something false. Capacity is dropped with it: a denominator alone
    -- invites the reader to supply the numerator.
    if state.connected then
        state.players = nil
        state.capacity = nil
    end

    -- Outside a session the signed identity still names the player.
    if not state.player or state.player == "" then
        local identity = Open77.network.identity()
        if identity and identity.displayName then
            state.player = tostring(identity.displayName)
        end
    end

    menu:send("pause:state", state)
end

-- Ping and the connection phase move while the menu is open, so the card is
-- refreshed once a second for as long as it is visible. The generation guard
-- kills an orphan loop if the menu is reopened quickly.
local stateLoopGeneration = 0
local setOpen

local function startStateLoop()
    stateLoopGeneration = stateLoopGeneration + 1
    local generation = stateLoopGeneration
    CreateThread(function()
        while open and generation == stateLoopGeneration do
            Wait(1000)
            if open and generation == stateLoopGeneration then
                local session = Open77.network.status()
                if not session or session.phase ~= "active" then
                    setOpen(false, true)
                else
                    publishState()
                end
            end
        end
    end)
end

setOpen = function(value, immediate, errorMessage)
    if not menu or (open == value and not immediate) then return end
    open = value
    menuGeneration = menuGeneration + 1
    mapRequest = nil
    local generation = menuGeneration
    if value then
        -- The WebUI owns input without entering a vanilla pause scenario.
        menu:show()
        if not menu:setFocus(true, true) then open = false; menu:hide(); return end
        publishState()
        menu:send("pause:open", {generation=generation, error=errorMessage})
        startStateLoop()
    else
        stateLoopGeneration = stateLoopGeneration + 1
        menu:send("pause:close", {generation=generation,immediate=immediate == true})
        -- Session/world transitions must not carry a modal or delayed focus
        -- release into the next world. Ordinary close retains its animation.
        if immediate then menu:setFocus(false, false);menu:hide();return end
        SetTimeout(260, function()
            if not open and generation == menuGeneration then
                menu:setFocus(false, false)
                menu:hide()
            end
        end)
    end
end

AddEventHandler("open77:map:requestFailed", function(result)
    if not mapRequest or not result or result.requestId ~= mapRequest.id then return end
    local request = mapRequest
    mapRequest = nil
    local session = Open77.network.status()
    if menuGeneration == request.generation and session and session.phase == "active" then
        setOpen(true, false, fmt(S.mapUnavailable, {reason=result.reason or "ui_unavailable"}))
    end
end)
AddEventHandler("open77:map:opened", function() mapRequest = nil end)

-- ---------------------------------------------------------------------------
-- Settings
--
-- Reading is a two-step because the script bridge is asynchronous and polls
-- five times a second: request a group, wait a beat, read what the script
-- reported. A tab may span several groups; they are read serially and sent to
-- the page as sections, under a generation guard so a fast tab switch cannot
-- interleave two reads.
local settingsGeneration = 0
local activeSettingsTab = ""
local voiceDevices = { input = {}, output = {} }
local voiceRestore = {
    endpoint = "",
    scalar = false,
    input = false,
    output = false,
    complete = false,
    lastError = "",
    attempts = 0,
    failed = false,
}
local voiceRestoreRunning = false
local voicePushToTalkKey = "N"

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

local function applyPushToTalkKey(value)
    local key, reason = normalizePushToTalkKey(value)
    if not key then return false, reason end
    local sent, sendReason = TriggerServerEvent("open77:voice:setPushToTalkKey", key)
    if sent ~= true then
        return false, tostring(sendReason or "push_to_talk_sync_failed")
    end
    voicePushToTalkKey = key
    return true, key
end

local function voiceFeedback(ok, message)
    message = tostring(message or
        (ok and S.voice.saved or fmt(S.voice.failed, { reason = "unknown_error" })))
    if menu and activeSettingsTab == "voice" then
        menu:send("voice:feedback", { ok = ok == true, message = message })
    end
    if ok ~= true then print("Open77 pause: " .. message) end
end

local function persistVoicePreference(key, value)
    local stored, reason = Open77.kvp.set(key, value)
    if stored ~= true then
        return false, "preference_not_saved:" .. tostring(reason or "kvp_write_failed")
    end
    return true
end

local function enumeratedVoiceDevices(flow, selected)
    local result = { { id = "", name = S.voice.systemDefault } }
    local devices = Open77.voice.devices(flow)
    if devices then
        for _, device in ipairs(devices) do
            if device.available ~= false and device.id ~= "" then
                result[#result + 1] = { id = device.id, name = device.name }
            end
        end
    end
    local index = 0
    local labels = {}
    for i, device in ipairs(result) do
        labels[i] = device.name
        if tostring(device.id) == tostring(selected or "") then index = i - 1 end
    end
    voiceDevices[flow] = result
    return labels, index
end

-- Declared above voiceSections because it calls them: a `local function`
-- referenced before its declaration resolves to a global, which here would
-- be nil.
local function voiceModeText(status)
    if status.voiceActivation then return S.voice.modeActivation end
    return fmt(S.voice.modePushToTalk, { key = voicePushToTalkKey })
end

local function voiceTransmitStateText(status)
    if status.captureEnabled ~= true then return S.voice.stateDisabled end
    if status.transmitting == true then return S.voice.stateTransmitting end
    if status.voiceActivation then return S.voice.stateReadyActivation end
    return fmt(S.voice.stateReadyPushToTalk, { key = voicePushToTalkKey })
end

local function voiceSections()
    local status, reason = Open77.voice.status()
    if not status then
        return {{ group = "voice", entries = {}, error = tostring(reason) }}
    end
    local inputs, inputIndex = enumeratedVoiceDevices("input", status.inputDevice)
    local outputs, outputIndex = enumeratedVoiceDevices("output", status.outputDevice)
    -- These rows are built here rather than read from the engine's settings
    -- tree -- voice is Open77's own subsystem -- so unlike an engine row their
    -- labels have no `meta` line to come from and are carried explicitly.
    return {{
        group = "voice", title = "voice",
        entries = {
            { name = "TransmitMode", label = S.voice.transmitMode, type = "info",
              value = voiceModeText(status) },
            { name = "TransmitState", label = S.voice.transmitState, type = "info",
              value = voiceTransmitStateText(status) },
            { name = "PushToTalkKey", label = S.voice.pushToTalkKey, type = "keybind",
              value = voicePushToTalkKey },
            { name = "InputDevice", label = S.voice.inputDevice, type = "list",
              value = inputIndex,
              min = 0, max = math.max(0, #inputs - 1), step = 1, options = inputs },
            { name = "OutputDevice", label = S.voice.outputDevice, type = "list",
              value = outputIndex,
              min = 0, max = math.max(0, #outputs - 1), step = 1, options = outputs },
            { name = "InputVolume", label = S.voice.inputVolume, type = "int",
              value = math.floor((tonumber(status.inputVolume) or 1) * 100 + 0.5),
              min = 0, max = 200, step = 1, suffix = "%" },
            { name = "OutputVolume", label = S.voice.outputVolume, type = "int",
              value = math.floor((tonumber(status.outputVolume) or 1) * 100 + 0.5),
              min = 0, max = 200, step = 1, suffix = "%" },
            { name = "VoiceReach", label = S.voice.reach, type = "info",
              value = fmt(S.voice.reachValue, { metres = string.format("%.0f",
                  tonumber(status.proximityDistance) or
                  tonumber(status.defaultProximityDistance) or 20) }) },
            { name = "CaptureEnabled", label = S.voice.captureEnabled, type = "bool",
              value = status.captureEnabled and 1 or 0 },
            { name = "VoiceActivation", label = S.voice.activation, type = "bool",
              value = status.voiceActivation and 1 or 0 },
            { name = "VoiceActivationThreshold", label = S.voice.activationThreshold,
              type = "int",
              value = math.floor((tonumber(status.voiceActivationThreshold) or 0.25) * 100 + 0.5),
              min = 0, max = 100, step = 1, suffix = "%" },
            { name = "MicrophoneTest", label = S.voice.microphoneTest, type = "bool",
              value = status.microphoneTest and 1 or 0 },
            { name = "InputLevel", label = S.voice.inputLevel, type = "meter",
              value = math.floor((tonumber(status.inputLevel) or 0) * 100 + 0.5),
              min = 0, max = 100, suffix = "%",
              threshold = math.floor((tonumber(status.voiceActivationThreshold) or 0.25) * 100 + 0.5) },
            { name = "OutputLevel", label = S.voice.outputLevel, type = "meter",
              value = math.floor((tonumber(status.outputLevel) or 0) * 100 + 0.5),
              min = 0, max = 100, suffix = "%" },
        }
    }}
end

local function setVoiceSetting(payload)
    local name = tostring(payload.name or "")
    local rawValue = payload.value
    local value = tonumber(rawValue) or 0
    local ok, reason
    if name == "InputDevice" or name == "OutputDevice" then
        local flow = name == "InputDevice" and "input" or "output"
        local device = voiceDevices[flow][math.floor(value) + 1]
        if not device then
            ok, reason = false, "selected_device_not_found"
        elseif #tostring(device.id or "") > 1024 then
            ok, reason = false, "selected_device_id_too_long"
        else
            ok, reason = Open77.voice.selectDevice(flow, device.id)
            if ok then
                ok, reason = persistVoicePreference("voice." .. flow .. "Device", device.id)
            end
        end
    elseif name == "InputVolume" then
        ok, reason = Open77.voice.setInputVolume(value / 100)
        if ok then ok, reason = persistVoicePreference("voice.inputVolume", value / 100) end
    elseif name == "OutputVolume" then
        ok, reason = Open77.voice.setOutputVolume(value / 100)
        if ok then ok, reason = persistVoicePreference("voice.outputVolume", value / 100) end
    elseif name == "PushToTalkKey" then
        ok, reason = applyPushToTalkKey(rawValue)
        if ok then ok, reason = persistVoicePreference("voice.pushToTalkKey", voicePushToTalkKey) end
    elseif name == "CaptureEnabled" then
        ok, reason = Open77.voice.setCaptureEnabled(value ~= 0)
        if ok then ok, reason = persistVoicePreference("voice.captureEnabled", value ~= 0) end
    elseif name == "VoiceActivation" then
        local current = Open77.voice.status()
        local threshold = current and current.voiceActivationThreshold or 0.25
        ok, reason = Open77.voice.setVoiceActivation(value ~= 0, threshold)
        if ok then ok, reason = persistVoicePreference("voice.activation", value ~= 0) end
    elseif name == "VoiceActivationThreshold" then
        local current = Open77.voice.status()
        ok, reason = Open77.voice.setVoiceActivation(
            current and current.voiceActivation == true, value / 100)
        if ok then
            ok, reason = persistVoicePreference("voice.activationThreshold", value / 100)
        end
    elseif name == "MicrophoneTest" then
        ok, reason = Open77.voice.setMicrophoneTest(value ~= 0)
    end
    if ok == true then
        voiceFeedback(true,
            name == "MicrophoneTest" and S.voice.microphoneTestUpdated or S.voice.saved)
    else
        voiceFeedback(false,
            fmt(S.voice.failed, { reason = tostring(reason or "unknown_error") }))
    end
end

local function resetVoiceRestore(endpoint)
    voiceRestore.endpoint = tostring(endpoint or "")
    voiceRestore.scalar = false
    voiceRestore.input = false
    voiceRestore.output = false
    voiceRestore.complete = false
    voiceRestore.lastError = ""
    voiceRestore.attempts = 0
    voiceRestore.failed = false
end

local function readVoicePreference(key, fallback)
    local value, reason = Open77.kvp.get(key, fallback)
    if value == nil then return nil, tostring(reason or "kvp_read_failed") end
    return value
end

local function restoreDevice(flow, desired, current)
    desired = tostring(desired or "")
    if #desired > 1024 then return false, "stored_" .. flow .. "_device_id_too_long" end
    if desired == tostring(current or "") then return true end
    if desired ~= "" then
        local devices, reason = Open77.voice.devices(flow)
        if not devices then return false, tostring(reason or (flow .. "_devices_not_ready")) end
        local found = false
        for _, device in ipairs(devices) do
            if device.available ~= false and tostring(device.id or "") == desired then
                found = true
                break
            end
        end
        if not found then return false, "stored_" .. flow .. "_device_unavailable" end
    end
    return Open77.voice.selectDevice(flow, desired)
end

local function restoreVoicePreferences(endpoint)
    if voiceRestore.endpoint ~= endpoint then resetVoiceRestore(endpoint) end
    local status, statusReason = Open77.voice.status()
    if not status or status.available ~= true then
        return false, tostring(statusReason or "voice_audio_not_ready")
    end

    local input, inputReadError = readVoicePreference("voice.inputDevice", "")
    if input == nil then return false, inputReadError end
    local output, outputReadError = readVoicePreference("voice.outputDevice", "")
    if output == nil then return false, outputReadError end

    local deviceError
    if not voiceRestore.input then
        voiceRestore.input, deviceError = restoreDevice("input", input, status.inputDevice)
    end
    if not voiceRestore.output then
        local outputOk, outputError = restoreDevice("output", output, status.outputDevice)
        voiceRestore.output = outputOk == true
        deviceError = deviceError or outputError
    end

    if not voiceRestore.scalar then
        local inputVolume, inputVolumeError = readVoicePreference("voice.inputVolume", 1.0)
        if inputVolume == nil then return false, inputVolumeError end
        local outputVolume, outputVolumeError = readVoicePreference("voice.outputVolume", 1.0)
        if outputVolume == nil then return false, outputVolumeError end
        local capture, captureError = readVoicePreference("voice.captureEnabled", true)
        if capture == nil then return false, captureError end
        local activation, activationError = readVoicePreference("voice.activation", false)
        if activation == nil then return false, activationError end
        local threshold, thresholdError = readVoicePreference("voice.activationThreshold", 0.25)
        if threshold == nil then return false, thresholdError end
        local pushToTalkKey, pushToTalkError = readVoicePreference("voice.pushToTalkKey", "N")
        if pushToTalkKey == nil then return false, pushToTalkError end

        local ok, reason = Open77.voice.setInputVolume(tonumber(inputVolume) or 1.0)
        if not ok then return false, reason end
        ok, reason = Open77.voice.setOutputVolume(tonumber(outputVolume) or 1.0)
        if not ok then return false, reason end
        ok, reason = Open77.voice.setCaptureEnabled(capture ~= false)
        if not ok then return false, reason end
        ok, reason = Open77.voice.setVoiceActivation(
            activation == true, tonumber(threshold) or 0.25)
        if not ok then return false, reason end
        ok, reason = applyPushToTalkKey(pushToTalkKey)
        if not ok then return false, reason end
        voiceRestore.scalar = true
    end

    voiceRestore.complete = voiceRestore.input and voiceRestore.output and voiceRestore.scalar
    if not voiceRestore.complete then return false, deviceError or "voice_devices_not_ready" end
    return true
end

local function startVoiceRestoreLoop()
    if voiceRestoreRunning then return end
    voiceRestoreRunning = true
    -- KVP is isolated by the authenticated server endpoint. At resource start
    -- the network session is commonly not active yet, so an immediate get()
    -- returns server_session_unavailable and used to silently select Windows
    -- defaults. Retry after the endpoint and native audio are ready, and again
    -- on a server switch. A temporarily unplugged saved endpoint is retained
    -- and retried rather than overwritten. This loop deliberately does not
    -- depend on WebUI creation: audio preferences remain functional if CEF is
    -- unavailable.
    CreateThread(function()
        while voiceRestoreRunning do
            local session = Open77.network.status()
            local endpoint = session and session.phase == "active" and
                tostring(session.endpoint or "") or ""
            if endpoint == "" then
                if voiceRestore.endpoint ~= "" then resetVoiceRestore("") end
                Wait(500)
            elseif voiceRestore.complete or voiceRestore.failed then
                -- Endpoint changes reset this state. A failed saved device is
                -- never replaced with the Windows default behind the user's
                -- back; reopening VOICE below offers another bounded pass.
                Wait(1000)
            else
                local restored, restoreError = restoreVoicePreferences(endpoint)
                if restored then
                    if voiceRestore.lastError ~= "" then
                        voiceFeedback(true, S.voice.restored)
                    end
                    voiceRestore.lastError = ""
                    voiceRestore.attempts = 0
                    Wait(1000)
                else
                    voiceRestore.attempts = voiceRestore.attempts + 1
                    restoreError = tostring(restoreError or "restore_failed")
                    if restoreError ~= voiceRestore.lastError then
                        voiceRestore.lastError = restoreError
                        voiceFeedback(false,
                            fmt(S.voice.restoreWaiting, { reason = restoreError }))
                    end
                    if voiceRestore.attempts >= 20 then
                        voiceRestore.failed = true
                        voiceFeedback(false, S.voice.restoreGaveUp)
                    end
                    Wait(750)
                end
            end
        end
    end)
end

-- ---------------------------------------------------------------------------
-- Key bindings
--
-- The engine owns the registry and the dispatch; this tab is only a viewer.
-- Every mapping any resource declared with RegisterKeyMapping is read from
-- Open77.input.mappings and shown as a `keybind` control -- the exact same
-- control the VOICE tab uses for push-to-talk. `name` is "resource|id" so the
-- write-back can address the mapping across resources; `label` carries the
-- human name the resource registered.
local function keybindSections()
    local mappings = Open77.input.mappings() or {}
    -- Stable display order so the list does not reshuffle when a resource
    -- re-registers (which fires open77:keybinds:changed and reloads this tab).
    table.sort(mappings, function(a, b)
        local an, bn = tostring(a.name or a.id), tostring(b.name or b.id)
        if an == bn then
            return tostring(a.resource) .. tostring(a.id) < tostring(b.resource) .. tostring(b.id)
        end
        return an < bn
    end)
    local entries = {}
    for _, m in ipairs(mappings) do
        entries[#entries + 1] = {
            name = tostring(m.resource) .. "|" .. tostring(m.id),
            label = tostring(m.name or m.id),
            type = "keybind",
            value = tostring(m.key or ""),
            default = tostring(m.defaultKey or ""),
            rebound = m.rebound == true,
        }
    end
    return {{ group = "keybinds", title = "keybinds", entries = entries }}
end

-- The page sends the captured key as the value, or the sentinel "__default__"
-- when the reset affordance is used. `name` is "resource|id".
local function setKeybind(payload)
    local name = tostring(payload.name or "")
    local separator = name:find("|", 1, true)
    if not separator then return end
    local resource = name:sub(1, separator - 1)
    local id = name:sub(separator + 1)
    if resource == "" or id == "" then return end

    local value = tostring(payload.value or "")
    local ok, reason
    if value == "__default__" then
        ok, reason = Open77.input.reset(resource, id)
    else
        ok, reason = Open77.input.rebind(resource, id, value)
    end
    -- Native emits open77:keybinds:changed on success, which reloads the tab so
    -- the readout always reflects the stored key rather than the optimistic one.
    if ok ~= true then
        print("Open77 pause: keybind change failed for " .. name .. ": " .. tostring(reason))
        -- Force a refresh so the page does not keep an unaccepted key on screen.
        if menu and activeSettingsTab == "keybinds" then
            menu:send("settings:values",
                { tab = "keybinds", sections = keybindSections(), done = true })
        end
    end
end

-- Reads one engine group and returns its entries, or nil plus a reason.
--
-- The bridge is asynchronous: `request` clears the buffer and queues a command,
-- the REDscript loop picks it up at its own 5 Hz cadence, and the answer lands
-- one `var.` line at a time. The old code slept a flat 450 ms per group, which
-- was fine when a tab was one group and is 2.3 s of blank list now that the
-- graphics tab is five.
--
-- So it polls, and accepts an answer only once the count has stopped moving.
-- Stability rather than "non-empty" because the lines are pushed from the
-- script thread while this reads from the Lua thread: a single non-empty read
-- can legitimately catch a group half-delivered. Two equal reads 60 ms apart
-- cannot, since one bridge tick delivers a whole group.
--
-- An empty group is a real answer -- `/gameplay` has no direct variables, and a
-- group this build does not publish (an upscaler the GPU does not have) returns
-- nothing at all -- so zero is accepted too, but only after 600 ms. That is
-- three bridge ticks: the command waits up to one tick to be taken and answers
-- within the next, so two would be the floor and this leaves a tick of margin.
local function readGroup(path)
    local ok, err = Open77.settings.request(path)
    if not ok then return nil, err end

    local previous = -1
    for attempt = 1, 18 do
        Wait(60)
        local values = Open77.settings.values() or {}
        local count = #values
        if count == previous and (count > 0 or attempt >= 10) then
            return values
        end
        previous = count
    end
    return Open77.settings.values() or {}
end

-- Folds each `meta` row into the variable it describes.
--
-- The script bridge emits two lines per variable -- `meta:` then the value --
-- and the native parser stores them as two entries under the same name
-- (client/src/api/ScriptBridge.cpp, ParseSettingLine). Merging happens here
-- rather than there because this is where the consumer is, and because the
-- parser would otherwise have to hold per-name state across calls on a channel
-- fed from another thread.
--
-- What the merge adds to an entry:
--
--   label      the engine's own localised name. Without it the page fell back
--              to camel-case splitting `ScreenSpaceReflectionsQuality`.
--   policy     when the change takes effect: immediate / confirm / restart /
--              checkpoint / disabled. The page turns the last three into a tag
--              on the row, which is the whole answer to "I changed it and
--              nothing happened".
--   scale      fixed-point divisor for a Float variable carried as an int.
--   visible    whether the game's own settings screen offers this one.
--   disabled   whether the engine currently refuses the write.
--   sub        whether it belongs under the row above it.
--   inGame     whether the engine applies it without returning to the menu.
--
-- A value line with no meta line keeps its defaults rather than being dropped:
-- a truncated meta line must not cost the player a control that works.
local function mergeSettingMeta(values)
    local meta = {}
    for _, entry in ipairs(values) do
        if entry.type == "meta" then
            local fields = entry.options or {}
            meta[entry.name] = {
                label = fields[1],
                policy = fields[2] or "unknown",
                flags = fields[3] or "-",
                scale = tonumber(fields[4]) or 1
            }
        end
    end

    local entries = {}
    for _, entry in ipairs(values) do
        if entry.type ~= "meta" then
            local row = meta[entry.name]
            if row then
                if row.label and row.label ~= "" then entry.label = row.label end
                entry.policy = row.policy
                entry.scale = (row.scale and row.scale > 0) and row.scale or 1
                entry.visible = row.flags:find("v", 1, true) ~= nil
                entry.disabled = row.flags:find("d", 1, true) ~= nil
                entry.sub = row.flags:find("s", 1, true) ~= nil
                entry.inGame = row.flags:find("g", 1, true) ~= nil
            end
            entries[#entries + 1] = entry
        end
    end
    return entries
end

local function pushSettings(tab)
    settingsGeneration = settingsGeneration + 1
    local generation = settingsGeneration
    if activeSettingsTab == "voice" and tab.id ~= "voice" then
        Open77.voice.setMicrophoneTest(false)
    end
    CreateThread(function()
        activeSettingsTab = tab.id
        if tab.voice then
            if voiceRestore.failed then
                voiceRestore.failed = false
                voiceRestore.attempts = 0
                voiceRestore.lastError = ""
            end
            if generation ~= settingsGeneration or not menu then return end
            menu:send("settings:values",
                { tab = tab.id, sections = voiceSections(), done = true })
            return
        end
        if tab.keybinds then
            if generation ~= settingsGeneration or not menu then return end
            menu:send("settings:values",
                { tab = tab.id, sections = keybindSections(), done = true })
            return
        end

        local sections = {}
        local total = #tab.groups
        if total == 0 then
            if menu and generation == settingsGeneration then
                menu:send("settings:values", { tab = tab.id, sections = {}, done = true })
            end
            return
        end
        for index, group in ipairs(tab.groups) do
            if generation ~= settingsGeneration then return end
            local values, err = readGroup(group.path)
            if not values then
                print("Open77 pause: settings request failed for " .. group.path ..
                    ": " .. tostring(err))
                values = {}
            end
            local entries = mergeSettingMeta(values)
            -- A group that answers nothing is not shown at all. That is not a
            -- filter on content: it is how a group this build does not publish
            -- (an upscaler the GPU does not have) stops being an empty heading.
            if #entries > 0 then
                sections[#sections + 1] = {
                    title = group.title, group = group.path, entries = entries
                }
            end
            if generation ~= settingsGeneration or not menu then return end
            -- Sent after every group instead of once at the end. Each group
            -- costs a bridge round trip, so a single send left the panel on
            -- "Loading" for the whole read; the page rebuilds from `sections`
            -- each time and keeps its loading tail until `done`.
            menu:send("settings:values", {
                tab = tab.id, sections = sections, done = index >= total
            })
        end
    end)
end

AddEventHandler("onClientResourceStart", function(name)
    if name ~= GetCurrentResourceName() then return end
    startVoiceRestoreLoop()

    local errorMessage
    -- Create once, then suspend the closed menu after its transition. The host
    -- now revalidates/repaints hidden views on reveal; a transparent fullscreen
    -- quad need not be blended over every game/frame-generation presentation.
    menu, errorMessage = WebUI.create({
        entry = "web/index.html", layer = "system", policy = "images",
        width = 1920, height = 1080, fps = 144,
        transparent = true, visible = true,
    })
    if not menu then
        print("Open77 pause menu WebUI failed: " .. tostring(errorMessage))
        return
    end
    -- Consume both keyboard streams, including the closing Escape's release.
    menu:setConsumedKeys({"escape"})

    menu:on("webui:host-lost", function()
        setOpen(false, true)
        Open77.session.setMenuReady(false)
    end)
    menu:on("pause:ready", function()
        -- A replacement document starts closed; discard any interrupted capture
        -- or modal state held by the old page before accepting Escape again.
        setOpen(false, true)
        TriggerEvent("open77:privacy:request")
        -- The string table FIRST: everything sent after it is rendered with it,
        -- and the page paints its static labels the moment it arrives.
        menu:send("pause:strings", S)
        publishBranding(true)
        publishState()
        local tabs = {}
        for index, tab in ipairs(TABS) do
            -- Only the id travels. The page resolves the word from
            -- `PauseStrings.tabs[id]`, so a tab name is not written twice.
            tabs[index] = { id = tab.id, enabled = tab.enabled }
        end
        menu:send("settings:tabs", { tabs = tabs })
        -- Declared only once the page itself has answered: from here on the
        -- plugin intercepts escape, and it must not do that before there is
        -- something to intercept it *for*.
        Open77.session.setMenuReady(true)
    end)

    menu:on("privacy:set", function(payload)
        TriggerEvent("open77:privacy:set", payload)
    end)

    menu:on("pause:logo-error", function()
        print("Open77 pause: server logo could not load; keeping the Open77 logo and menu available.")
    end)
    menu:on("pause:closed", function(payload)
        if type(payload) ~= "table" or payload.generation ~= menuGeneration then return end
        -- Browser-initiated close retires the open generation. An immediate
        -- host close already did so; keep any map request made in that generation.
        if open then menuGeneration = menuGeneration + 1 end
        open = false
        stateLoopGeneration = stateLoopGeneration + 1
        Open77.voice.setMicrophoneTest(false)
        menu:setFocus(false, false)
        menu:hide()
    end)

    menu:on("settings:closed", function()
        activeSettingsTab = ""
        Open77.voice.setMicrophoneTest(false)
    end)

    menu:on("settings:open", function(payload)
        pushSettings(tabByName(payload and payload.tab))
    end)

    menu:on("settings:set", function(payload)
        if not payload or not payload.name or not payload.group then return end
        if payload.group == "voice" then
            setVoiceSetting(payload)
            return
        end
        if payload.group == "keybinds" then
            setKeybind(payload)
            return
        end
        Open77.settings.set(payload.group, payload.name,
            math.floor(tonumber(payload.value) or 0))
    end)

    CreateThread(function()
        while menu do
            if open and activeSettingsTab == "voice" then
                local status = Open77.voice.status()
                if status then
                    menu:send("voice:levels", {
                        input = math.floor((tonumber(status.inputLevel) or 0) * 100 + 0.5),
                        output = math.floor((tonumber(status.outputLevel) or 0) * 100 + 0.5),
                        talking = status.localTalking == true,
                        transmitting = status.transmitting == true,
                        threshold = math.floor((tonumber(status.voiceActivationThreshold) or 0.25) * 100 + 0.5),
                        mode = voiceModeText(status),
                        state = voiceTransmitStateText(status),
                        proximity = tonumber(status.proximityDistance),
                        proximityPending = status.proximityRequestPending == true,
                    })
                end
                Wait(75)
            else
                Wait(250)
            end
        end
    end)

    menu:on("pause:vanilla-settings", function()
        -- The vanilla settings screen remains reachable as the "advanced"
        -- surface -- key bindings, accessibility, everything this panel does
        -- not render. It is its own menu scenario and freezes the world while
        -- open; that is accepted for a deliberate, rare action.
        setOpen(false, true)
        Open77.session.openSettings()
    end)

    menu:on("pause:action", function(payload)
        local action = payload and payload.action or ""
        if action == "map" then
            setOpen(false, true)
            local ticket, reason = Open77.map.open()
            if not ticket then
                print("Open77 map: " .. tostring(reason))
                setOpen(true, false, fmt(S.mapUnavailable, {reason=reason or "map_unavailable"}))
            else
                mapRequest = {id=ticket, generation=menuGeneration}
            end
        elseif action == "quit-session" then
            -- The native session lifecycle owns the rest: the phase leaves
            -- `active`, the client host notices, covers the screen, walks the
            -- engine back to the main menu and remounts the server browser
            -- with this reason. Nothing else to drive from here.
            print("Open77 pause: quit session requested.")
            Open77.network.disconnect("user_quit")
            setOpen(false)
        elseif action == "quit-game" then
            -- The vanilla exit-to-desktop path, through the script bridge.
            local ok, err = Open77.session.quitGame()
            if not ok then
                print("Open77 pause: quit game failed: " .. tostring(err))
            end
            setOpen(false)
        end
    end)
end)

-- Hands escape back to the game when this resource stops, so a reload or a
-- crash never leaves the player without any menu at all.
AddEventHandler("onClientResourceStop", function(name)
    if name ~= GetCurrentResourceName() then return end
    voiceRestoreRunning = false
    Open77.voice.setMicrophoneTest(false)
    Open77.session.setMenuReady(false)
end)

-- Raised by the plugin for every escape press it swallows.
AddEventHandler("open77:pauseKey", function()
    -- The system host runs before the server-resource host, so the focus
    -- snapshot still belongs to the modal that received this Escape press.
    -- Its own pauseKey handler closes it; do not also open a second modal.
    -- A cursor-only page (an inventory panel) closes on this same press: the
    -- second result of isCaptured() says a page holds the cursor.
    local keyboard, cursor = Open77.input.isCaptured()
    if not open and (keyboard or cursor == true) then return end
    setOpen(not open)
end)

AddEventHandler("open77:worldReady", function()
    setOpen(false, true)
end)

-- The engine raises this whenever the key-mapping registry changes -- a resource
-- (re)registered a binding, or a rebind/reset landed. If the KEY BINDINGS tab is
-- on screen, reload it so the list and every readout stay truthful.
AddEventHandler("open77:keybinds:changed", function()
    if open and activeSettingsTab == "keybinds" and menu then
        menu:send("settings:values",
            { tab = "keybinds", sections = keybindSections(), done = true })
    end
end)
