-- Clock mutation remains owned by open77_weather; this resource supplies only
-- an authoritative Dogtown match projection. No competing SetTime loop.
local active = false
local function project(value)
    local ok, accepted = pcall(function()
        return exports.open77_weather.setMatchClock(value)
    end)
    if ok and accepted then active = value ~= nil end
end
AddEventHandler("cordon:state:local", function(payload)
    if type(payload) ~= "table" then return end
    if type(payload.night) == "table" then project(payload.night)
    elseif active then project(nil) end
end)
AddEventHandler("onClientResourceStop", function(name)
    if name == GetCurrentResourceName() and active then project(nil) end
end)
