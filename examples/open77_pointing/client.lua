-- Optional example: hold B, or use /pointing on|off|status.
-- Pointing remains owned by this resource; the animation service handles
-- interruptions, resource teardown and replication.
local function setPointing(enabled)
    local request, dispatchError = Open77.animations.setPointing(enabled)
    if not request then print('pointing: ' .. tostring(dispatchError)); return end
    CreateThread(function()
        local result, err = request:await()
        print('pointing: ' .. (err and tostring(err) or json.encode(result)))
    end)
end

RegisterKeyMapping('point', 'Point with your finger', 'B',
    function() setPointing(true) end,
    function() setPointing(false) end)

RegisterNetEvent('open77_pointing:command', function(action)
    if action == 'on' then setPointing(true)
    elseif action == 'off' then setPointing(false)
    elseif action == 'status' then
        CreateThread(function()
            local request, err = Open77.animations.isPointing()
            if not request then print('pointing: ' .. tostring(err)); return end
            local active, failure = request:await()
            print('pointing active=' .. tostring(active) .. ' error=' .. tostring(failure))
        end)
    end
end)
