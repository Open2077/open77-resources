-- Cooperative administration of THIS resource's vehicles. No client event,
-- no arbitrary command dispatch, and no transfer of entity ownership.
local commands = {remove = "admin.veh.remove", repair = "admin.veh.repair", flag = "admin.veh.flag"}
local safeRepair = {glass=true, body=true, lights=true, tires=true, visual=true}
exports("adminVehicleAction", function(actor, id, operation, value, enabled)
    if GetInvokingResource() ~= "open77_admin" then return false, "forbidden_resource" end
    local command = commands[operation]
    if not command or type(actor) ~= "number" or actor < 1 or actor % 1 ~= 0
        or not Open77.acl.isAllowed(actor, "command." .. command) then return false, "permission_denied" end
    local vehicle = Open77.vehicles.get(id)
    if not vehicle or vehicle.resource ~= GetCurrentResourceName() then return false, "not_owner" end
    local position = Open77.players.position(actor)
    local at = vehicle
    if not position or not at or position.bucket ~= vehicle.bucket
        or (position.x-at.x)^2+(position.y-at.y)^2+(position.z-at.z)^2 > 20^2 then
        return false, "target_out_of_range_or_bucket"
    end
    local occupied = false
    for _, occupant in ipairs(vehicle.occupants or {}) do
        if tonumber(type(occupant) == "table" and occupant.playerId or occupant) then occupied = true; break end
    end
    if operation == "remove" then
        if occupied then return false, "vehicle_occupied" end
        return Open77.vehicles.remove(id)
    elseif operation == "repair" then
        if not safeRepair[value] and value ~= "full" and value ~= "mechanical" then return false, "invalid_scope" end
        if occupied and not safeRepair[value] then return false, "vehicle_occupied_use_visual" end
        return Open77.vehicles.repair(id, value)
    elseif operation == "flag" then
        if value ~= "locked" or type(enabled) ~= "boolean" then return false, "unsupported_flag" end
        local mask = Open77.vehicles.flags[value]
        if not mask then return false, "unsupported_flag" end
        local bits = vehicle.flags or 0
        return Open77.vehicles.update(id, {flags = enabled and (bits | mask) or (bits & ~mask)})
    end
    return false, "invalid_operation"
end)
