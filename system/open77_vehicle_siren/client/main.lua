local nextRequest = 0

local function toggle()
    local seat = Open77.vehicles.getPlayerSeat()
    if not seat or seat.seat ~= "seat_front_left" or seat.entering or seat.exiting then
        return false, "not_driver"
    end
    local now = Open77.time.monotonic() * 1000
    if now < nextRequest then return false, "cooldown" end
    nextRequest = now + Open77VehicleSiren.cooldownMs
    -- Send the intended vehicle, never a desired state or a player ID. A delayed
    -- keypress must not toggle another car after the player changes seats.
    return TriggerServerEvent("open77:vehicleSiren:toggle", seat.vehicleId)
end

local ok, key = RegisterKeyMapping("vehicle_siren", "Vehicle: toggle siren",
    Open77VehicleSiren.defaultKey, toggle)
if not ok then print("[open77_vehicle_siren] key mapping failed: " .. tostring(key)) end

exports("toggle", toggle)
