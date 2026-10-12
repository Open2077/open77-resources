-- The player's half of third person.
--
-- Three jobs, and nothing else: a key the player can press and reassign, a
-- preference that survives a reconnection, and the receipt of the server's
-- policy. Every one of them ends in a call to `Open77.perspective`, which asks
-- `Api::PerspectiveArbiter`; this file never touches `Open77.camera`.
--
-- That restraint is the point. The arbiter moves six ownership values together
-- -- camera, body, input, weapon, effects, audio -- and checks six invariants
-- over them every frame. A resource that reached for `Open77.camera.thirdPerson`
-- to "just move the camera" would move one of the six and leave five behind,
-- which is the split state the arbiter exists to prevent. Ask; never decide.
--
-- Layering of the preference, which is easy to get backwards: the KVP value is
-- what the PLAYER wants and is written whether or not the server honours it.
-- The arbiter separately remembers the request it refused, so a `forced` pin
-- that is later lifted restores the right view without this file doing
-- anything. Both are needed: the arbiter's memory does not survive a
-- reconnection, and KVP does not survive a change of server.

local DEFAULT_KEY = "f6"

-- Chosen because it collides with nothing: no vanilla 2.31 gameplay binding and
-- no shipped Open77 resource (`open-voice` holds F11, `open77_voice` holds N).
-- It is a default, not a fixture -- `setKey` moves it and the move persists.

local KVP_MODE = "perspective.mode"
local KVP_KEY = "perspective.key"

-- The allowlist `Open77.input.isDown` enforces (`ResourceHost.cpp`,
-- `ValidActionKey`). Checked here as well so a bad `setKey` is refused where the
-- player can see the refusal, rather than becoming a key that silently never
-- fires.
local VALID_KEYS = {
    space = true, enter = true, ["return"] = true, tab = true, shift = true,
    ctrl = true, control = true, alt = true, capslock = true, backspace = true,
    insert = true, delete = true, home = true, ["end"] = true,
    pageup = true, pagedown = true, up = true, down = true, left = true, right = true,
}
for index = 1, 12 do VALID_KEYS["f" .. index] = true end
for byte = string.byte("a"), string.byte("z") do VALID_KEYS[string.char(byte)] = true end
for byte = string.byte("0"), string.byte("9") do VALID_KEYS[string.char(byte)] = true end

local POLL_MS = 10
local ANNOUNCE_INTERVAL_MS = 2000
local ANNOUNCE_ATTEMPTS = 5

local preferred = "fpp"
local preferenceLoaded = false
local toggleKey = DEFAULT_KEY
local policy = { policy = "allowed", perspective = "fpp", owner = "" }
local policyReceived = false

local function normalise(mode)
    mode = tostring(mode or ""):lower()
    if mode == "tps" or mode == "tpp" or mode == "third" then return "tps" end
    if mode == "fpp" or mode == "first" then return "fpp" end
    return nil
end

local function available()
    return type(Open77.perspective) == "table" and type(Open77.perspective.set) == "function"
end

-- KVP is namespaced by connection address, so it does not exist until the
-- session is Active: a read before then returns `server_session_unavailable`.
-- Nothing is cached on failure, so the next caller retries.
local function loadPreferences()
    if preferenceLoaded then return true end
    if type(Open77.kvp) ~= "table" then return false end

    local mode, modeReason = Open77.kvp.get(KVP_MODE, nil)
    if mode == nil and modeReason ~= nil then return false end
    local normalised = normalise(mode)
    if mode ~= nil and normalised == nil then
        -- Written by an older shape of this code, or by hand. Heal rather than
        -- carry a value nothing can interpret.
        Open77.kvp.delete(KVP_MODE)
    end
    preferred = normalised or "fpp"

    local key = Open77.kvp.get(KVP_KEY, nil)
    if type(key) == "string" and VALID_KEYS[key:lower()] then
        toggleKey = key
    elseif key ~= nil then
        Open77.kvp.delete(KVP_KEY)
    end

    preferenceLoaded = true
    return true
end

local function persist(key, value)
    if type(Open77.kvp) ~= "table" then return end
    local ok, reason = Open77.kvp.set(key, value)
    if not ok then
        Open77.log.warn(("perspective: '%s' not saved (%s)"):format(key, tostring(reason)))
    end
end

--- Asks for the stored preference. Safe to call repeatedly: the arbiter treats
--- a repeat of the request it already holds as a no-op.
local function applyPreference()
    if not available() then return false, "perspective_unavailable_on_this_host" end
    return Open77.perspective.set(preferred)
end

local function setMode(mode)
    local normalised = normalise(mode)
    if normalised == nil then return false, "invalid_perspective" end
    loadPreferences()
    preferred = normalised
    -- Written before the request is made, and deliberately: the preference is
    -- the player's, not the arbiter's. A server that refuses it today must not
    -- erase what the player asked for, or moving to a server that allows third
    -- person would drop them into first.
    persist(KVP_MODE, preferred)
    return applyPreference()
end

local function toggle()
    loadPreferences()
    local target = preferred == "tps" and "fpp" or "tps"
    return setMode(target)
end

local function setKey(key)
    key = tostring(key or ""):lower()
    if not VALID_KEYS[key] then return false, "unsupported_action_key" end
    loadPreferences()
    toggleKey = key
    persist(KVP_KEY, toggleKey)
    return true
end

RegisterNetEvent("open77:perspective:policy", function(payload)
    if type(payload) ~= "table" then return end
    local value = tostring(payload.policy or "")
    if value ~= "disabled" and value ~= "allowed" and value ~= "default"
        and value ~= "forced" then
        Open77.log.warn("perspective: server sent an unknown policy '" .. value .. "'")
        return
    end
    local pinned = normalise(payload.perspective) or "fpp"

    policy = { policy = value, perspective = pinned, owner = tostring(payload.owner or "") }
    policyReceived = true

    if not available() then return end
    local ok, reason = Open77.perspective.applyPolicy(value, pinned)
    if not ok then
        Open77.log.error("perspective: policy not applied (" .. tostring(reason) .. ")")
        return
    end

    -- Re-assert after every policy change. Under `allowed` and `default` this
    -- restores the player's own choice; under `disabled` and `forced` it is
    -- refused and merely records the intent, which is what makes a later lift
    -- of the pin land on the right view.
    loadPreferences()
    applyPreference()
    TriggerEvent("open77:perspective:policyChanged", value, pinned)
end)

AddEventHandler("open77:perspective:toggle", function() toggle() end)

AddEventHandler("onClientResourceStart", function(name)
    if name ~= GetCurrentResourceName() then return end

    if not available() then
        Open77.log.error(
            "perspective: Open77.perspective is absent on this client build -- the toggle " ..
            "cannot work. Rebuild the plugin.")
        return
    end
    if type(Open77.input) ~= "table" or type(Open77.input.isDown) ~= "function" then
        Open77.log.error("perspective: Open77.input is absent; the toggle key cannot be read")
        return
    end
    local _, refusal = Open77.input.isDown("f1")
    if refusal ~= nil then
        Open77.log.error("perspective: the keyboard cannot be read (" .. tostring(refusal) ..
            ") -- the manifest must grant input.actions")
    end

    -- Ask the server for its policy. A server on which no resource declares one
    -- never answers, and the client keeps the platform default `allowed`; that
    -- is why this gives up rather than pinging forever.
    CreateThread(function()
        for _ = 1, ANNOUNCE_ATTEMPTS do
            if policyReceived then return end
            TriggerServerEvent("open77:perspective:ready")
            Wait(ANNOUNCE_INTERVAL_MS)
        end
    end)

    -- Restore the stored preference once the session is up. `open77:worldReady`
    -- does not fire after a hot reload -- the world is already there -- so the
    -- restore has to be able to happen from the start path too, and KVP is not
    -- readable until the connection address exists.
    CreateThread(function()
        for _ = 1, 60 do
            if loadPreferences() then
                applyPreference()
                return
            end
            Wait(500)
        end
    end)

    -- The key. `isDown` is a LEVEL read, so the down-transition is computed
    -- here; without it a held key would toggle at poll rate. A key that is
    -- already down when this starts is suppressed until it is released once,
    -- which is the trap `open77_admin` documents: pressing Enter to send the
    -- chat command that started this resource would otherwise fire it at once.
    CreateThread(function()
        local wasDown = true
        while true do
            local down = false
            if not Open77.input.isCaptured() then
                down = Open77.input.isDown(toggleKey) == true
            end
            if down and not wasDown then
                local ok, reason = toggle()
                if not ok then
                    Open77.log.info("perspective: " .. tostring(reason))
                end
            end
            wasDown = down
            Wait(POLL_MS)
        end
    end)

    -- Reticle rendering belongs to open77_reticle in the client bootstrap,
    -- independently of this optional server policy/preference resource.
end)

AddEventHandler("open77:worldReady", function()
    if not available() then return end
    if loadPreferences() then applyPreference() end
end)

exports("get", function()
    if not available() then return nil, "perspective_unavailable_on_this_host" end
    return Open77.perspective.get()
end)

exports("set", function(mode) return setMode(mode) end)
exports("toggle", function() return toggle() end)

exports("state", function()
    if not available() then return nil, "perspective_unavailable_on_this_host" end
    local state = Open77.perspective.state()
    if state == nil then return nil, "perspective_unavailable" end
    state.preferred = preferred
    state.key = toggleKey
    state.policyOwner = policy.owner
    state.policyReceived = policyReceived
    return state
end)

exports("key", function() return toggleKey end)
exports("setKey", function(key) return setKey(key) end)
