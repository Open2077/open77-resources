-- =============================================================================
-- open77_fuel -- client
-- =============================================================================
--
-- The client half of a state-bag feature is a READ. The server owns `fuel` on
-- every vehicle's bag; every client streaming the car already has the number
-- in its mirror, so a gauge costs no event, no request and no permission.
--
-- `exports.open77_fuel:level(id)` is GetVehicleFuelLevel for a ported script,
-- and `Open77.state.entity("vehicle", id).fuel` is the same value for anyone
-- who would rather not go through an export. The change handler re-emits the
-- delta as a local event so a HUD can subscribe by name without knowing the
-- bag's shape.
--
-- There is no `set` here, and there never will be: the client never writes a
-- bag (wiki/state-bags.md). A fuel gauge a client could set is a fuel gauge a
-- client can cheat.
-- =============================================================================

local KEY = "fuel"

local function level(id)
    if type(id) == "string" then id = tonumber(id) end
    if type(id) ~= "number" then return nil, "invalid_vehicle_id" end
    local bag = Open77.state.entity("vehicle", id)
    if bag == nil then return nil, "state_unavailable" end
    local value = bag:get(KEY)
    if type(value) ~= "number" then return nil, "unknown" end
    return value
end

exports("level", level)

-- The vehicle the local player is sitting in, when it is a canonical one: the
-- ungated character read says which REDengine entity the body is mounted in,
-- and `Open77.vehicles.fromEntity` (this is what `vehicles.read` is held for)
-- maps that entity back to the canonical id the bag is keyed on.
local function currentVehicle()
    local state = Open77.character and Open77.character.state and Open77.character.state()
    if type(state) ~= "table" or type(state.vehicle) ~= "table" or not state.vehicle.mounted then return nil end
    if Open77.vehicles and Open77.vehicles.fromEntity then
        local snapshot = Open77.vehicles.fromEntity(state.vehicle.entity)
        if type(snapshot) == "table" and snapshot.id ~= nil then return snapshot.id end
    end
    return nil
end

exports("current", function()
    local id = currentVehicle()
    if id == nil then return nil, "not_in_vehicle" end
    return level(id)
end)

-- `open77:fuel:changed` (vehicleId, litres, previous) for HUDs and scripts.
if Open77.state and Open77.state.onChange then
    Open77.state.onChange("vehicle", KEY, function(selector, _, value, previous)
        local id = tonumber(selector and selector.id)
        if id == nil then return end
        TriggerEvent("open77:fuel:changed", id, value, previous)
    end)
end
