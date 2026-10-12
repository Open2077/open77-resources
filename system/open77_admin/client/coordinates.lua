-- Read the actual local character, not the life service's last respawn heading.
-- Every player receives this handler. Nothing here grants admin authority.
RegisterNetEvent("open77_admin:coordinates", function(kind)
    if kind ~= "pos" and kind ~= "rot" then return end
    local state = Open77.character.state()
    local text, copied
    if state and state.attached and state.position and state.orientation then
        local function clean(value)
            value = tonumber(value) or 0
            return math.abs(value) < .0000005 and 0 or value
        end
        if kind == "pos" then
            local p = state.position
            text = string.format("position = { x = %.6f, y = %.6f, z = %.6f }", clean(p.x), clean(p.y), clean(p.z))
        else
            local q = state.orientation
            text = string.format("orientation = { x = %.6f, y = %.6f, z = %.6f, w = %.6f }, yaw = %.6f",
                clean(q.x), clean(q.y), clean(q.z), clean(q.w), clean(state.yaw))
        end
        copied = Open77.clipboard.setText(text) == true
    else
        text = "Character transform unavailable. Enter the world first."
    end
    local message = copied and ("Copied: " .. text) or text
    Open77.log.info("/" .. kind .. " " .. message)
    TriggerEvent("open77:command:result", kind, copied == true, message)
    TriggerEvent("open77_admin:notice", { title = kind == "pos" and "POSITION" or "ROTATION · DEGREES", text = message })
end)
