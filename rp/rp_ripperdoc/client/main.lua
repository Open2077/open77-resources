-- rp_ripperdoc client: the ALT+click "Quote" action on another player (open77_contextmenu). It is a
-- request: the server decides who may quote, whom, for what, and what it costs. The chair, the
-- station and the chrome dealer are open77_actions prompts, drawn by that library.
local RESOURCE = GetCurrentResourceName()
local cfg = RpRipperConfig

local onDuty = false        -- pushed by the server (rp_ripperdoc:duty)

local function call(resource, name, ...)
    local promise, reason = Open77.exports.call(resource, name, ...)
    if not promise then return nil, reason end
    return promise:await()
end

-- Context-menu predicates and callbacks must be exports of THIS resource.
exports("rpRipperCanQuote", function(context)
    local target = context and context.target
    if not target or target.kind ~= "player" or target.isLocalPlayer then return false end
    if target.playerId == nil then return false end
    return onDuty == true
end)

exports("rpRipperQuote", function(context)
    local target = context and context.target
    if not target or target.playerId == nil then return false end
    -- Only the canonical target id crosses to the server; it re-checks everything.
    TriggerServerEvent("rp_ripperdoc:quote", target.playerId)
    return true
end)

local function registerQuote()
    local token, reason = call("open77_contextmenu", "registerPlayers", {
        id = "rp_ripperdoc_quote",
        label = "Quote",
        description = "Open the ripperdoc catalogue and send this patient a quote.",
        group = "Ripperdoc",
        icon = "tool",
        networked = true,
        distance = cfg.quote.distance,
        order = 40,
        canInteract = "rpRipperCanQuote",
        onSelect = "rpRipperQuote",
    })
    if not token then print("[rp_ripperdoc] context-menu action refused: " .. tostring(reason)) end
end

RegisterNetEvent("rp_ripperdoc:duty", function(flag)
    onDuty = (flag == true or flag == "true" or flag == 1)
end)

AddEventHandler("onClientResourceStart", function(name)
    if name == RESOURCE then
        CreateThread(function()
            registerQuote()
            TriggerServerEvent("rp_ripperdoc:clientReady")
        end)
    elseif name == "open77_contextmenu" then
        CreateThread(registerQuote)
    end
end)
