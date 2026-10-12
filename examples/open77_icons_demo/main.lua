-- Opt-in presentation demo. Creates local-only blips near the player after
-- world entry; does not teleport, spawn entities or mutate server state.
CreateThread(function()
    while true do
        local state = Open77.character.state()
        if state and state.alive and state.attached and state.position then
            Wait(6000)
            state = Open77.character.state()
            if state and state.alive and state.attached and state.position then
                local p = state.position
                local icons = { "fuel", "hospital", "car", "grape" }
                local colors = { "#FFCC00", "#FF5577", "#00DDCC", "#BB88FF" }
                local handles = {}
                local info = exports.open77_icons:info()
                assert(info.count == 2112 and info.apiAvailable, "icon catalogue unavailable")
                assert(exports.open77_icons:has("fuel"))
                assert(exports.open77_icons:list("fuel").icons[1] == "fuel")
                for i, name in ipairs(icons) do
                    local id, reason = exports.open77_icons:create({
                        icon=name, color=colors[i], size=48,
                        title="Lucide // " .. name,
                        position={x=p.x+(i-2.5)*14, y=p.y+22, z=p.z},
                        visibleThroughWalls=true,
                    })
                    assert(id, name .. ": " .. tostring(reason))
                    handles[i]=id
                end
                print("open77_icons demo: 2112 catalogue; fuel/hospital/car/grape created (grape exceeds old 384-polygon limit)")
                Wait(45000)
                assert(exports.open77_icons:setIcon(handles[3], "wrench", 56))
                assert(exports.open77_icons:setColor(handles[1], "#00CCFF"))
                assert(exports.open77_icons:get(handles[1]))
                print("open77_icons demo: live update passed (cyan fuel, wrench replaces car)")
                return
            end
        end
        Wait(1000)
    end
end)
