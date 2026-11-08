-- Client half: run a sequence from a client script and react to its phases.
local current

local function run()
    if current then return end
    local id, reason = exports.open77_braindance:start({ preset = "glitch", hold = true, tag = "client-example" })
    if not id then return print("[bd-example] start refused: " .. tostring(reason)) end
    current = id
    print("[bd-example] started " .. id)
end

AddEventHandler("open77_braindance:black", function(id)
    if id ~= current then return end
    print("[bd-example] black, client-side work, then resume")
    CreateThread(function()
        Wait(1000)
        print("[bd-example] resume -> " .. tostring(exports.open77_braindance:resume(id)))
    end)
end)

AddEventHandler("open77_braindance:phase", function(id, phase)
    if id ~= current then return end
    print(("[bd-example] %s -> %s"):format(id, phase))
    if phase == "finished" or phase == "cancelled" then current = nil end
end)

RegisterNetEvent("open77_braindance_example:run", run)
RegisterKeyMapping("bd_example", "Braindance example transition", "B", run)

-- Braindance layers: N walks VISUAL -> THERMAL -> AUDIO -> off. Any interface
-- (layer name, timeline) is the resource's own; it listens to the layer event.
local cycle = { "visual", "thermal", "audio", "off" }
local step = 0
local function nextLayer()
    step = step % #cycle + 1
    local layer = cycle[step]
    local ok, reason = exports.open77_braindance:setLayer(layer)
    if not ok then return print("[bd-example] layer refused: " .. tostring(reason)) end
end

AddEventHandler("open77_braindance:layer", function(layer, previous)
    print(("[bd-example] layer %s -> %s"):format(previous, layer))
end)

RegisterKeyMapping("bd_example_layer", "Braindance example: next layer", "N", nextLayer)
