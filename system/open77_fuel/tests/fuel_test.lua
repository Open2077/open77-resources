-- =============================================================================
-- open77_fuel -- tests/fuel_test.lua
-- =============================================================================
-- Unit tests for shared/fuel.lua: the two rates, the idle threshold, the
-- rounding, the zero floor and the "ran out" edge the server acts on.
--
-- Runs two ways:
--   * In the C# suite: Open77.Server.Tests.Resources.FuelModelTests loads
--     shared/fuel.lua first (it sets the FuelModel global) and then runs this
--     file, asserting on the TestResult global below.
--   * Standalone:  lua tests/fuel_test.lua   (needs Lua 5.4; the file loads
--     shared/fuel.lua itself when FuelModel is not set).
-- =============================================================================

local M = FuelModel
if M == nil then
    local chunk = loadfile("shared/fuel.lua") -- standalone only
    assert(chunk, "shared/fuel.lua not found -- run from the resource dir")
    chunk()
    M = FuelModel
end

local passed, failures = 0, {}
local function check(cond, msg)
    if cond then
        passed = passed + 1
    else
        failures[#failures + 1] = msg or "assertion failed"
    end
end

local function near(a, b, eps)
    return math.abs(a - b) <= (eps or 1e-6)
end

local function run(name, fn)
    local okRun, err = pcall(fn)
    if not okRun then
        failures[#failures + 1] = name .. ": runtime error: " .. tostring(err)
    end
end

-- ---------------------------------------------------------------------------
-- config
-- ---------------------------------------------------------------------------
run("config fills gaps and refuses junk", function()
    local c = M.config({ capacity = 40, multiplier = "lots", bogus = 3, litresPerHundredKm = 0 / 0 })
    check(c.capacity == 40, "capacity override kept")
    check(c.multiplier == M.DEFAULTS.multiplier, "a string multiplier is ignored")
    check(c.bogus == nil, "an unknown key is not stored")
    check(c.litresPerHundredKm == M.DEFAULTS.litresPerHundredKm, "NaN is ignored")
    check(M.config(nil).capacity == M.DEFAULTS.capacity, "nil overrides are the defaults")
    local d = M.config({})
    d.capacity = 1
    check(M.DEFAULTS.capacity ~= 1, "config does not alias the defaults table")
end)

-- ---------------------------------------------------------------------------
-- burn
-- ---------------------------------------------------------------------------
run("a stopped engine burns nothing at any speed", function()
    check(M.burn(false, 30, 1) == 0, "engine off, moving")
    check(M.burn(false, 0, 60) == 0, "engine off, idle")
end)

run("moving burns by distance at litres per hundred km", function()
    local c = M.config({ litresPerHundredKm = 10, multiplier = 1 })
    -- 20 m/s for 50 s = 1 km = 0.1 L at 10 L/100km.
    check(near(M.burn(true, 20, 50, c), 0.1), "1 km at 10 L/100km is 0.1 L")
    check(near(M.burn(true, 20, 100, c), 0.2), "twice the time, twice the fuel")
    check(near(M.burn(true, 40, 50, c), 0.2), "twice the speed, twice the fuel")
end)

run("idling burns by time at litres per minute", function()
    local c = M.config({ idleLitresPerMinute = 0.6, multiplier = 1 })
    check(near(M.burn(true, 0, 60, c), 0.6), "one minute idle")
    check(near(M.burn(true, 0.5, 60, c), 0.6), "below walking pace counts as idle")
    check(near(M.burn(true, 1.0, 60, c), 60 * 1.0 / 1000 * c.litresPerHundredKm / 100), "1 m/s is moving")
end)

run("the multiplier scales both rates", function()
    local c = M.config({ litresPerHundredKm = 10, idleLitresPerMinute = 0.6, multiplier = 3 })
    check(near(M.burn(true, 20, 50, c), 0.3), "moving x3")
    check(near(M.burn(true, 0, 60, c), 1.8), "idle x3")
end)

run("bad inputs burn nothing rather than NaN", function()
    check(near(M.burn(true, 0 / 0, 60), M.DEFAULTS.idleLitresPerMinute), "NaN speed is idle, not NaN")
    check(M.burn(true, -5, 1) >= 0, "negative speed is not a refund")
    check(M.burn(true, 10, 0) == 0, "zero dt")
    check(M.burn(true, 10, -1) == 0, "negative dt")
    check(M.burn(true, 10, 0 / 0) == 0, "NaN dt")
end)

-- ---------------------------------------------------------------------------
-- step
-- ---------------------------------------------------------------------------
run("a tank the model has never seen starts full", function()
    local c = M.config({ capacity = 50 })
    local level, ranOut = M.step(nil, false, 0, 1, c)
    check(level == 50, "nil level is the capacity")
    check(ranOut == false, "starting full is not running out")
    local nan, _ = M.step(0 / 0, false, 0, 1, c)
    check(nan == 50, "a NaN level is treated as unseen")
end)

run("step rounds to a tenth and floors at zero", function()
    local c = M.config({ litresPerHundredKm = 10, multiplier = 1 })
    -- 0.02 L burned from 1.0 rounds to 1.0: the bag must not move for a
    -- change a gauge would not show.
    local level = M.step(1.0, true, 20, 10, c)
    check(level == 1.0, "0.02 L rounds away, got " .. tostring(level))
    level = M.step(1.0, true, 20, 50, c)
    check(near(level, 0.9), "0.1 L shows, got " .. tostring(level))
    local floor, ranOut = M.step(0.05, true, 40, 1000, c)
    check(floor == 0, "never negative")
    check(ranOut == true, "crossing zero is the edge")
end)

run("the ran-out edge fires once, on the crossing", function()
    local c = M.config({ litresPerHundredKm = 100, multiplier = 10 })
    local level, ranOut = M.step(0.3, true, 30, 10, c)
    check(level == 0 and ranOut == true, "first crossing")
    level, ranOut = M.step(0, true, 30, 10, c)
    check(level == 0 and ranOut == false, "already empty is not a second crossing")
    level, ranOut = M.step(0, false, 0, 10, c)
    check(level == 0 and ranOut == false, "an empty parked car stays empty quietly")
end)

-- ---------------------------------------------------------------------------
-- clamp
-- ---------------------------------------------------------------------------
run("clamp keeps a refuel inside the tank", function()
    local c = M.config({ capacity = 60 })
    check(M.clamp(200, c) == 60, "over capacity")
    check(M.clamp(-4, c) == 0, "below zero")
    check(M.clamp(12.345, c) == 12.3, "tenth of a litre")
    check(M.clamp("full", c) == nil, "not a number")
    check(M.clamp(0 / 0, c) == nil, "NaN")
end)

-- ---------------------------------------------------------------------------
-- Result contract for the C# host.
-- ---------------------------------------------------------------------------
TestResult = { passed = passed, failed = #failures, failures = failures }

print(string.format("[open77_fuel tests] %d passed, %d failed", passed, #failures))
for _, f in ipairs(failures) do
    print("  FAIL: " .. f)
end
if #failures > 0 and os ~= nil and os.exit ~= nil then
    os.exit(1)
end
