local nextRequest = {}

RegisterNetEvent("open77:vehicleSiren:toggle", function(vehicleId)
    local playerId = math.tointeger(tonumber(source))
    if not playerId or playerId <= 0 or type(vehicleId) ~= "number"
        or not math.tointeger(vehicleId) or vehicleId <= 0 then return end

    local now = Open77.time.monotonic() * 1000
    if now < (nextRequest[playerId] or 0) then return end
    nextRequest[playerId] = now + Open77VehicleSiren.cooldownMs

    if not Open77.ready.isReady(playerId) then return end
    local seat = Open77.vehicles.getPlayerSeat(playerId)
    if not seat or seat.vehicleId ~= vehicleId or seat.seat ~= "seat_front_left"
        or seat.entering or seat.exiting then return end

    local vehicle = Open77.vehicles.get(vehicleId)
    if not vehicle or vehicle.destroyed or vehicle.health <= 0 then return end
    local enabled = Open77.vehicles.isSirenOn(vehicleId)
    if type(enabled) ~= "boolean" then return end

    -- The canonical setter updates every projection, late join and stream-in.
    -- It also preserves engine, headlights, locks and all other vehicle flags.
    local ok, reason = Open77.vehicles.setSiren(vehicleId, not enabled)
    if not ok then print("[open77_vehicle_siren] toggle failed: " .. tostring(reason)) end
end)

AddEventHandler("onPlayerDisconnected", function(playerId)
    nextRequest[tonumber(playerId)] = nil
end)
