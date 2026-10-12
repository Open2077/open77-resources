-- =============================================================================
-- open77_fuel -- shared/fuel.lua
-- =============================================================================
--
-- The consumption model, and nothing else: no Open77 call, no bag, no timer.
-- It is pure so the server test suite can run it in a bare Lua state
-- (tests/fuel_test.lua) and so a server owner tuning the numbers can read the
-- whole rule on one screen.
--
-- Units. Fuel is LITRES, speed is METRES PER SECOND -- the unit every Open77
-- read uses -- and the two rates are the ones a car's spec sheet quotes:
-- litres per hundred kilometres when moving, litres per minute when idling.
-- `multiplier` scales both; a server that wants arcade rates, or a proof that
-- wants to watch a tank drain in twenty seconds, changes one number.
-- =============================================================================

FuelModel = FuelModel or {}

FuelModel.DEFAULTS = {
    capacity = 60.0,               -- litres; every new tank starts full
    litresPerHundredKm = 12.0,     -- burned by distance while moving
    idleLitresPerMinute = 0.08,    -- burned by time while the engine idles
    multiplier = 1.0,              -- scales both rates
}

--- Fills the gaps in a config table from the defaults, without mutating it.
function FuelModel.config(overrides)
    local config = {}
    for key, value in pairs(FuelModel.DEFAULTS) do config[key] = value end
    if type(overrides) == "table" then
        for key, value in pairs(overrides) do
            if FuelModel.DEFAULTS[key] ~= nil and type(value) == "number" and value == value then
                config[key] = value
            end
        end
    end
    return config
end

--- Litres burned over `dtSeconds` at `speedMps` with the engine `engineOn`.
--
-- A stopped engine burns nothing, whatever the speed says: a car being towed
-- or rolling downhill with the ignition off has no combustion to account for.
-- Below walking pace the distance term is dropped and the idle term applies,
-- so a car creeping in traffic is charged as idling rather than as a fraction
-- of a millilitre per second that rounds to nothing.
function FuelModel.burn(engineOn, speedMps, dtSeconds, config)
    if not engineOn then return 0.0 end
    if type(speedMps) ~= "number" or speedMps ~= speedMps or speedMps < 0 then speedMps = 0.0 end
    if type(dtSeconds) ~= "number" or dtSeconds ~= dtSeconds or dtSeconds <= 0 then return 0.0 end
    config = config or FuelModel.DEFAULTS
    local litres
    if speedMps >= 1.0 then
        local km = speedMps * dtSeconds / 1000.0
        litres = km * config.litresPerHundredKm / 100.0
    else
        litres = config.idleLitresPerMinute * dtSeconds / 60.0
    end
    return litres * config.multiplier
end

--- One tick of the model for one vehicle.
--
-- `level` is the current litres (nil for a car the model has never seen, which
-- starts full). Returns the new level, floored at zero and rounded to a tenth
-- of a litre so the replicated bag only moves when the number a HUD would show
-- moves, and a boolean that is true on the tick the tank RAN OUT -- the one
-- edge the server acts on.
function FuelModel.step(level, engineOn, speedMps, dtSeconds, config)
    config = config or FuelModel.DEFAULTS
    if type(level) ~= "number" or level ~= level then level = config.capacity end
    local before = level
    level = level - FuelModel.burn(engineOn, speedMps, dtSeconds, config)
    if level < 0.0 then level = 0.0 end
    level = math.floor(level * 10.0 + 0.5) / 10.0
    return level, (before > 0.0 and level <= 0.0)
end

--- Clamps a refuel or a set into the tank.
function FuelModel.clamp(level, config)
    config = config or FuelModel.DEFAULTS
    if type(level) ~= "number" or level ~= level then return nil end
    if level < 0.0 then level = 0.0 end
    if level > config.capacity then level = config.capacity end
    return math.floor(level * 10.0 + 0.5) / 10.0
end
