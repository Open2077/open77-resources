-- No claim on startup: other packages may own the camera until the player
-- explicitly selects a Freeroam style. Native ownership/cleanup is resource scoped.
local styles = { "classic", "shoulder", "centered" }
local selected = 1
local cinematic = false
local function report(message)
    TriggerEvent("chat:addMessage", { type = "system", author = "CAMERA", text = message, color = { 34, 216, 226 } })
end
RegisterNetEvent("freeroam:camera:change", function(request)
    local api = Open77.camera
    if not api.configureThirdPerson then return report("Camera styles require an updated Open77 client.") end
    local name = tostring(request or ""):lower()
    if name == "reset" then
        local ok, why = api.resetThirdPerson()
        if ok then selected = 1 end
        return report(ok and "Camera style released; default framing restored." or tostring(why))
    end
    if name == "shake" then
        local ok, why = api.shakeThirdPerson({ duration = 0.65, frequency = 8, amplitude = { x = 0.03, y = 0.015, z = 0.02 } })
        return report(ok and "Camera shake preview." or tostring(why))
    end
    if name == "left" or name == "right" then
        local state = api.thirdPersonState()
        if not state or not state.owned then return report("Select a camera style first: /camchange shoulder") end
        local ok, why = api.configureThirdPerson({ shoulder = name })
        return report(ok and ("Camera shoulder: " .. name) or tostring(why))
    end
    local nextIndex
    if name == "" then nextIndex = selected % #styles + 1
    else for index, value in ipairs(styles) do if value == name then nextIndex = index end end end
    if not nextIndex then return report("/camchange [classic|shoulder|centered|left|right|shake|reset]") end
    local ok, why = api.configureThirdPerson({ style = styles[nextIndex] })
    if not ok then return report(tostring(why)) end
    local enabled, reason = Open77.perspective.set("third")
    if not enabled then
        api.resetThirdPerson()
        return report(tostring(reason))
    end
    selected = nextIndex
    report("Third-person camera: " .. styles[selected] .. " — /camchange to cycle; /camchange reset to release.")
end)

RegisterNetEvent("freeroam:camera:cinematic", function(request)
    if not Open77.hud.setCinematic then return report("Cinematic mode requires an updated Open77 client.") end
    local enabled = not cinematic
    if request == "on" then enabled = true elseif request == "off" then enabled = false end
    local ok, why = Open77.hud.setCinematic(enabled)
    if not ok then return report(tostring(why)) end
    cinematic = enabled
    -- Do not emit a toast or chat message over a clean cinematic capture.
    if not cinematic then report("Cinematic mode disabled.") end
end)
