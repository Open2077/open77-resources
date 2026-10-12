-- Read-only developer surface over the native vehicle replication manager.
if type(Open77.vehicles) ~= "table" or type(Open77.vehicles.all) ~= "function" then
    print("[open77_vehicles] native network vehicle API unavailable; restart Cyberpunk")
    return
end

RegisterNetEvent("open77:command:result", function(raw, accepted, message)
    if type(raw) ~= "string" or string.match(string.lower(raw), "^vehicle%.") == nil then return end
    print(string.format("[server command] %s %s: %s", accepted and "OK" or "ERR", raw, tostring(message)))
end)

AddEventHandler("open77:vehicleCreated", function(id)
    print(string.format("[open77_vehicles] streamed in vehicle %s", tostring(id)))
end)

AddEventHandler("open77:vehicleRemoved", function(id, reason)
    print(string.format("[open77_vehicles] streamed out vehicle %s reason=%s", tostring(id), tostring(reason)))
end)

AddEventHandler("open77:vehicleAuthorityChanged", function(id, owner)
    TriggerEvent("open77:vehicleOwnerChanged", tonumber(id), tonumber(owner))
end)

AddEventHandler("open77:vehicleOccupancyChanged", function(id, revision)
    local vehicle = Open77.vehicles.get(tonumber(id))
    if vehicle == nil then return end
    TriggerEvent("open77:vehicleSeatsChanged", vehicle, tonumber(revision))
end)

exports("get", function(id) return Open77.vehicles.get(tonumber(id)) end)
exports("all", function() return Open77.vehicles.all() end)
exports("getPlayerSeat", function(playerId)
    if playerId == nil then return Open77.vehicles.getPlayerSeat() end
    return Open77.vehicles.getPlayerSeat(tonumber(playerId))
end)
exports("isPlayerExitLocked", function(playerId)
    if playerId == nil then return Open77.vehicles.isPlayerExitLocked() end
    return Open77.vehicles.isPlayerExitLocked(tonumber(playerId))
end)

-- Read-only live probe used to diagnose replication without exposing any
-- client-side vehicle mutation. Invoke with:
--   resource.emit open77:vehicles:probe
RegisterNetEvent("open77:vehicles:probe", function()
    local vehicles = Open77.vehicles.all()
    print(string.format("[open77_vehicles] probe vehicles=%d", #vehicles))
    for _, vehicle in ipairs(vehicles) do
        local occupants = {}
        for _, occupant in ipairs(vehicle.occupants or {}) do
            occupants[#occupants + 1] = string.format(
                "%s:%s flags=%s forcedEntry=%s exitLocked=%s forcedExit=%s",
                tostring(occupant.seat), tostring(occupant.playerId), tostring(occupant.flags),
                tostring(occupant.forcedEntry), tostring(occupant.exitLocked),
                tostring(occupant.forcedExit))
        end
        print(string.format(
            "[open77_vehicles] probe id=%s entity=%s streamed=%s localOwner=%s owner=%s epoch=%s speed=%.3f rpm=%.1f throttle=%.3f brake=%.3f steering=%.3f wheel=%.3f occupants=[%s]",
            tostring(vehicle.id), tostring(vehicle.entity), tostring(vehicle.streamed),
            tostring(vehicle.locallyOwned), tostring(vehicle.physicsOwner), tostring(vehicle.authorityEpoch),
            tonumber(vehicle.speed) or 0.0, tonumber(vehicle.rpm) or 0.0,
            tonumber(vehicle.throttle) or 0.0, tonumber(vehicle.brake) or 0.0,
            tonumber(vehicle.steering) or 0.0, tonumber(vehicle.wheelRotation) or 0.0,
            table.concat(occupants, ",")))
    end
end)

print("network vehicle projection ready")

-- Bounded, read-only HUD/API diagnostic. Uses the same public Lua facade as
-- resources; no raw engine pointers or development mutation escape hatch.
RegisterNetEvent("open77:vehicles:weapons:probe", function()
    if type(Open77.vehicles.getWeaponState) ~= "function" then
        print("[open77_vehicles] weapons probe unavailable; client update required")
        return
    end
    for index, vehicle in ipairs(Open77.vehicles.all()) do
        if index > 32 then break end
        local state, reason = Open77.vehicles.getWeaponState(vehicle.id)
        if state then
            print(string.format("[open77_vehicles] weapons id=%s record=%s declared=%d attached=%s active=%s localDriver=%s",
                tostring(vehicle.id), state.record, state.declaredCount,
                tostring(state.attachedCount), tostring(state.activeCount), tostring(state.localDriver)))
            for _, weapon in ipairs(state.mounts) do
                if weapon.attached then
                    local ammo = weapon.ammo
                    print(string.format("[open77_vehicles] weapon index=%d type=%s active=%s ammo=%s/%s total=%s source=%s heat=%s trigger=%s",
                        weapon.index, weapon.type, tostring(weapon.active), tostring(ammo.magazine),
                        tostring(ammo.capacity), tostring(ammo.total), ammo.source,
                        tostring(weapon.overheat), tostring(weapon.triggerMode)))
                end
            end
        else
            print("[open77_vehicles] weapons error=" .. tostring(reason))
        end
    end
end)
