-- Compact Open Stress Test watermark, top-centre inside CHROME_STRIP.
--
-- The page is a passive hud-layer surface: it is never focused, so it can
-- never swallow input, and the CSS disables pointer events entirely. Local
-- facts (runtime version, Lua version, resource generation) are read here;
-- the session identity is only ever what the server answered, so the overlay
-- shows the authoritative identity or OFFLINE — never a client-made value.

local page
local identity          -- last server-provided identity, nil while offline
local identityFresh = false

local function publish()
    if page == nil then return end
    page:send("watermark:state", {
        version = Open77.runtime.version(),
        luaVersion = Open77.runtime.luaVersion(),
        generation = Open77.resource.generation(),
        online = identity ~= nil,
        playerId = identity ~= nil and identity.playerId or nil,
        name = identity ~= nil and identity.name or nil,
        identifier = identity ~= nil and identity.identifier or nil,
    })
end

RegisterNetEvent("watermark:state", function(payload)
    if type(payload) ~= "table" then return end
    identity = payload
    identityFresh = true
    publish()
end)

AddEventHandler("onClientResourceStart", function(name)
    if name ~= GetCurrentResourceName() then return end

    local errorMessage
    page, errorMessage = WebUI.create({
        entry = "web/index.html",
        layer = "hud",
        width = 1920,
        height = 1080,
        fps = 10,
        zIndex = 900,
        transparent = true,
        visible = true,
    })
    if page == nil then
        print("[open77_watermark] WebUI failed: " .. tostring(errorMessage))
        return
    end

    page:on("watermark:ready", publish)

    -- Ask the server for the session identity: quickly until the first answer
    -- arrives, then slowly to follow reconnects. A send failure just means the
    -- session is not active yet — the overlay stays in OFFLINE mode.
    CreateThread(function()
        while true do
            identityFresh = false
            local accepted = TriggerServerEvent("watermark:ready")
            if not accepted then
                identity = nil
                publish()
            end
            Wait(identity ~= nil and 60000 or 5000)
            -- A session drop leaves the last identity on screen otherwise:
            -- when a slow-cycle refresh got no answer, fall back to OFFLINE.
            if identity ~= nil and not identityFresh then
                identity = nil
                publish()
            end
        end
    end)
end)

AddEventHandler("onClientResourceStop", function(name)
    if name ~= GetCurrentResourceName() then return end
    page = nil
    identity = nil
end)
