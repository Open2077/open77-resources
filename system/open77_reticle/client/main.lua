-- F7 works without any server resource. Its ADS reticle must do so too.
-- Only presentation: do not request a perspective or read a physical mouse
-- button (controller, toggle-aim and rebound inputs use the same game state).
local page, ready, lastVisible

local function wantsReticle()
    local state = Open77.perspective.state()
    return state ~= nil and state.available == true and state.engaged == true
        and state.camera == "open77_rig" and state.body == "proxy"
        and state.input == "player" and state.aiming == true
        and Open77.character.isAlive() == true
        and Open77.character.isArmed() == true
        and not Open77.input.isCaptured()
end

local function refresh(force)
    if not page or not ready then return end
    local visible = wantsReticle()
    if force or visible ~= lastVisible then
        lastVisible = visible
        page:send("reticle:state", { visible = visible, aiming = visible })
        if visible then page:show() else page:hide() end
    end
end

AddEventHandler("onClientResourceStart", function(name)
    if name ~= GetCurrentResourceName() then return end
    local reason
    page, reason = WebUI.create({
        entry = "web/index.html", layer = "hud", width = 1920, height = 1080,
        fps = 30, zIndex = 850, transparent = true, visible = true,
    })
    if not page then
        Open77.log.error("reticle: WebUI failed (" .. tostring(reason) .. ")")
        return
    end
    -- Browser readiness is asynchronous. A send-on-change before ready can
    -- otherwise lose the initial state until the player aims a second time.
    page:on("reticle:ready", function()
        ready = true
        refresh(true)
    end)
    CreateThread(function()
        while true do
            refresh(false)
            Wait(16)
        end
    end)
end)
