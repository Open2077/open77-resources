-- =============================================================================
-- open77_fuel -- server
-- =============================================================================
--
-- Fuel is a state-bag field. The server owns one number, `fuel`, on every
-- canonical vehicle's bag (`Open77.state.entity("vehicle", id)`, which is
-- `Entity(id).state` in the FiveM spelling); every client that streams the car
-- receives it automatically and reads it with no permission and no event.
--
-- Once a second this resource walks the registry, reads the replicated motion
-- and engine state the physics owner already reports -- `get(id).speed`,
-- `isEngineOn(id)` -- and burns the tank through the pure model in
-- shared/fuel.lua. At zero it cuts the engine with `Open77.vehicles.setEngine`,
-- which is server-authored and held against the owner's next report, and keeps
-- it cut until somebody refuels. That is the whole feature, and it needs no
-- native: FiveM's GetVehicleFuelLevel is `exports.open77_fuel:level(id)` or a
-- bare bag read, SetVehicleFuelLevel is `exports.open77_fuel:set(id, litres)`.
--
-- What this is NOT: a client-authored value. The client never writes the bag
-- (see wiki/state-bags.md, "The client never writes a bag"); a fuel gauge that
-- a client could set is a fuel gauge a client can cheat. Consumption is derived
-- from the owner's replicated speed, which the server already validates.
-- =============================================================================

local CONFIG = FuelModel.config({
    -- See FuelModel.DEFAULTS for the units. Change them here or at runtime
    -- through `exports.open77_fuel:configure{ ... }` / `/fuel.multiplier`.
})
local TICK_MS = 1000
local KEY = "fuel"

-- Vehicles whose engine this resource has cut for an empty tank, so the
-- `open77:fuel:empty` event fires once per empty and not once per tick.
local cut = {}

local function bag(id)
    return Open77.state.entity("vehicle", id)
end

local function level(id)
    local value = bag(id):get(KEY)
    if type(value) == "number" then return value end
    return nil
end

local function write(id, litres)
    local ok, reason = bag(id):set(KEY, litres)
    if not ok then
        print(("[open77_fuel] could not write fuel for vehicle %s: %s"):format(tostring(id), tostring(reason)))
    end
    return ok
end

-- One tick for one vehicle. `read` is the server snapshot from `all()`.
local function tick(read, dtSeconds)
    local id = read.id
    local current = level(id)
    -- The engine bit is on the snapshot's flags; isEngineOn is the same read.
    local engineOn = (read.flags & Open77.vehicles.flags.engineOn) ~= 0
    local next, ranOut = FuelModel.step(current, engineOn, read.speed or 0.0, dtSeconds, CONFIG)
    if current == nil or next ~= current then
        write(id, next)
    end
    if next <= 0.0 then
        -- Empty. Cut the engine, and keep cutting it: the owner's report can
        -- restart it (a driver pressing the ignition), and the platform holds a
        -- server-authored bit against that report for ten seconds, so a cut
        -- every second is what keeps the car dead until it is refuelled.
        if engineOn then Open77.vehicles.setEngine(id, false) end
        if ranOut or not cut[id] then
            cut[id] = true
            print(("[open77_fuel] vehicle %s ran out of fuel"):format(tostring(id)))
            TriggerEvent("open77:fuel:empty", id)
        end
    elseif cut[id] then
        cut[id] = nil
    end
end

CreateThread(function()
    while true do
        Wait(TICK_MS)
        local all = Open77.vehicles.all()
        if type(all) == "table" then
            for index = 1, #all do
                local read = all[index]
                if type(read) == "table" and read.id ~= nil and not read.destroyed then
                    local ok, err = pcall(tick, read, TICK_MS / 1000.0)
                    if not ok then
                        print(("[open77_fuel] tick failed for vehicle %s: %s"):format(tostring(read.id), tostring(err)))
                    end
                end
            end
        end
    end
end)

-- A removed vehicle takes its bag with it (the host destroys entity bags with
-- their subject); only the local "already cut" mark has to go.
AddEventHandler("onVehicleRemoved", function(id)
    cut[tonumber(id) or id] = nil
end)

-- ---- Exports ----------------------------------------------------------------
--
-- `level` is GetVehicleFuelLevel; `set` is SetVehicleFuelLevel; `refuel` is the
-- pump. All three answer `value | nil, reason`, and every write goes through
-- the same clamp as the model so a refuel can never overfill the tank.

local function known(id)
    if type(id) == "string" then id = tonumber(id) end
    if type(id) ~= "number" then return nil, "invalid_vehicle_id" end
    if Open77.vehicles.get(id) == nil then return nil, "vehicle_not_found" end
    return id
end

exports("level", function(id)
    local vehicle, reason = known(id)
    if vehicle == nil then return nil, reason end
    -- A car the tick has not reached yet reads as full: the model starts full.
    return level(vehicle) or CONFIG.capacity
end)

exports("capacity", function()
    return CONFIG.capacity
end)

local function setLevel(id, litres)
    local vehicle, reason = known(id)
    if vehicle == nil then return nil, reason end
    local clamped = FuelModel.clamp(litres, CONFIG)
    if clamped == nil then return nil, "invalid_level" end
    if not write(vehicle, clamped) then return nil, "state_write_failed" end
    -- A set above zero is a refuel as far as the cut engine is concerned; the
    -- driver still has to start it, exactly as after a real fill-up.
    if clamped > 0.0 then cut[vehicle] = nil end
    return clamped
end

local function refuel(id, litres)
    local vehicle, reason = known(id)
    if vehicle == nil then return nil, reason end
    local amount = litres
    if amount == nil then amount = CONFIG.capacity end
    if type(amount) ~= "number" or amount ~= amount or amount < 0 then return nil, "invalid_amount" end
    return setLevel(vehicle, (level(vehicle) or CONFIG.capacity) + amount)
end

exports("set", setLevel)
exports("refuel", refuel)

-- Runtime tuning. Only the keys the model knows are accepted, and only as
-- positive numbers; anything else is ignored rather than stored. The effective
-- table comes back so a caller can read the numbers it is now running on.
local function configure(overrides)
    if type(overrides) == "table" then
        for key, value in pairs(overrides) do
            if FuelModel.DEFAULTS[key] ~= nil and type(value) == "number" and value == value and value > 0 then
                CONFIG[key] = value
            end
        end
    end
    local view = {}
    for key, value in pairs(CONFIG) do view[key] = value end
    return view
end

exports("configure", configure)

-- ---- Commands ---------------------------------------------------------------

RegisterCommand("fuel", function(source, args)
    local vehicle, reason = known(args[1])
    if vehicle == nil then print("[open77_fuel] " .. tostring(reason)) return end
    print(("[open77_fuel] vehicle %s fuel=%.1f/%.1f engine=%s speed=%.1f"):format(
        tostring(vehicle), level(vehicle) or CONFIG.capacity, CONFIG.capacity,
        tostring(Open77.vehicles.isEngineOn(vehicle)), Open77.vehicles.get(vehicle).speed or 0.0))
end, false)

RegisterCommand("refuel", function(source, args)
    local vehicle, reason = known(args[1])
    if vehicle == nil then print("[open77_fuel] " .. tostring(reason)) return end
    local after, why = refuel(vehicle, tonumber(args[2]))
    print(("[open77_fuel] vehicle %s refuel -> %s %s"):format(tostring(vehicle), tostring(after), why or ""))
end, true)

RegisterCommand("fuel.set", function(source, args)
    local vehicle, reason = known(args[1])
    if vehicle == nil then print("[open77_fuel] " .. tostring(reason)) return end
    local after, why = setLevel(vehicle, tonumber(args[2]))
    print(("[open77_fuel] vehicle %s set -> %s %s"):format(tostring(vehicle), tostring(after), why or ""))
end, true)

RegisterCommand("fuel.multiplier", function(source, args)
    local value = tonumber(args[1])
    if value == nil or value <= 0 then print("[open77_fuel] usage: fuel.multiplier <factor>") return end
    local view = configure({ multiplier = value })
    print(("[open77_fuel] consumption multiplier=%.2f (%.1f L/100km, %.2f L/min idle)"):format(
        view.multiplier, view.litresPerHundredKm, view.idleLitresPerMinute))
end, true)

print(("[open77_fuel] ready -- %.0f L tanks, %.1f L/100km, %.2f L/min idle; /fuel <id>, /refuel <id> [litres]")
    :format(CONFIG.capacity, CONFIG.litresPerHundredKm, CONFIG.idleLitresPerMinute))
