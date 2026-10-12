-- =============================================================================
-- open77_avcleanup -- tests/sweep_test.lua
-- =============================================================================
-- Unit tests for shared/sweep.lua: the AV-record filter, the vacancy rules
-- (lease guard + occupant guard) and the grace state machine, plus
-- integration sweeps over the runSweep pass (arming, graduation, forced
-- sweeps, failed removals, vanished-vehicle cleanup).
--
-- Runs two ways:
--   * In the C# suite: Open77.Server.Tests.Resources.AvCleanupSweepTests
--     loads shared/sweep.lua first (it sets the AvCleanupSweep global) and
--     then runs this file, asserting on the TestResult global below.
--   * Standalone:  lua tests/sweep_test.lua   (needs Lua 5.4; the file
--     loads shared/sweep.lua itself when AvCleanupSweep is not set).
-- =============================================================================

local S = AvCleanupSweep
if S == nil then
    local chunk = loadfile("shared/sweep.lua") -- standalone only
    assert(chunk, "shared/sweep.lua not found -- run from the resource dir")
    S = chunk()
end

local passed, failures = 0, {}
local function check(cond, msg)
    if cond then
        passed = passed + 1
    else
        failures[#failures + 1] = msg or "assertion failed"
    end
end

local function run(name, fn)
    local okRun, err = pcall(fn)
    if not okRun then
        failures[#failures + 1] = name .. ": runtime error: " .. tostring(err)
    end
end

-- ---------------------------------------------------------------------------
-- isAvRecord: the AV-record filter
-- ---------------------------------------------------------------------------
run("isAvRecord", function()
    check(S.isAvRecord("Vehicle.av_militech_manticore"), "manticore is an AV")
    check(S.isAvRecord("Vehicle.av_rayfield_excalibur"), "excalibur is an AV")
    check(S.isAvRecord("Vehicle.av_zetatech_atlus"), "atlus is an AV")
    check(S.isAvRecord("Vehicle.max_tac_av"), "max_tac_av is an AV")
    check(S.isAvRecord("Vehicle.av_"), "bare prefix is an AV")
    check(not S.isAvRecord("Vehicle.v_standard2_archer_hella_player"), "ground car is NOT an AV")
    check(not S.isAvRecord("Vehicle.av"), "10-char prefix is NOT an AV")
    check(not S.isAvRecord("vehicle.av_militech_manticore"), "lowercase prefix is NOT an AV")
    check(not S.isAvRecord(123), "non-string is NOT an AV")
    check(not S.isAvRecord(nil), "nil is NOT an AV")
    check(not S.isAvRecord(""), "empty string is NOT an AV")
end)

-- ---------------------------------------------------------------------------
-- isVacant: occupants + lease guard
-- ---------------------------------------------------------------------------
run("isVacant", function()
    check(S.isVacant({ occupants = {}, physicsOwner = 0 }), "empty + unleased is vacant")
    check(S.isVacant({}), "no fields is vacant")
    check(S.isVacant({ occupants = {}, physicsOwner = 0, record = "x" }), "extra fields are ignored")
    check(not S.isVacant({ occupants = { 1 } }), "one occupant is NOT vacant")
    check(not S.isVacant({ occupants = {}, physicsOwner = 42 }), "leased is NOT vacant")
    check(not S.isVacant({ occupants = { 1 }, physicsOwner = 42 }), "occupied + leased is NOT vacant")
end)

-- ---------------------------------------------------------------------------
-- step: the grace state machine
-- ---------------------------------------------------------------------------
run("grace state machine", function()
    check(S.step(nil, 1000, 5, false) == "watch", "first sight arms the timer")
    check(S.step(1000, 1004.9, 5, false) == "within-grace", "4.9 min < grace stays within")
    check(S.step(1000, 1005, 5, false) == "remove", "exactly at grace removes")
    check(S.step(1000, 1006, 5, false) == "remove", "past grace removes")
    check(S.step(1000, 1001, 5, true) == "remove", "forced removes an armed AV early")
    check(S.step(nil, 1001, 5, true) == "watch", "forced first sight still arms (production order)")
    check(S.step(1000, 1000, 0, false) == "remove", "zero grace removes at the same instant")
    check(S.step(1000, 999, 5, false) == "within-grace", "clock rollback stays within grace")
end)

-- ---------------------------------------------------------------------------
-- runSweep: integration passes
-- ---------------------------------------------------------------------------
local function vehicle(id, record, occupants, physicsOwner)
    return {
        id = id,
        record = record,
        occupants = occupants or {},
        physicsOwner = physicsOwner or 0,
        x = 1, y = 2, z = 3,
    }
end

run("runSweep: AV-record filter", function()
    local state = {}
    local removedIds = {}
    -- First sweep arms the two vacant AVs; the ground car, the occupied AV
    -- and the leased AV are never candidates.
    S.runSweep({
        vehicle(1, "Vehicle.av_militech_manticore"),
        vehicle(2, "Vehicle.v_standard2_archer_hella_player"), -- ground car: never touched
        vehicle(3, "Vehicle.max_tac_av"),
        vehicle(4, "Vehicle.av_militech_manticore", { 9 }),     -- occupied: never touched
        vehicle(5, "Vehicle.av_militech_manticore", {}, 7),     -- leased: never touched
    }, state, 1000, 5, false, function() return true end)
    check(state[1] == 1000 and state[3] == 1000, "vacant AVs armed")
    check(state[2] == nil and state[4] == nil and state[5] == nil,
        "ground car / occupied / leased never enter grace state")
    -- Forced sweep: only the armed vacant AVs are removed.
    local n, still = S.runSweep({
        vehicle(1, "Vehicle.av_militech_manticore"),
        vehicle(2, "Vehicle.v_standard2_archer_hella_player"),
        vehicle(3, "Vehicle.max_tac_av"),
        vehicle(4, "Vehicle.av_militech_manticore", { 9 }),
        vehicle(5, "Vehicle.av_militech_manticore", {}, 7),
    }, state, 1001, 5, true, function(id)
        removedIds[#removedIds + 1] = id
        return true
    end)
    check(n == 2, "forced sweep removes the 2 armed vacant AVs (got " .. tostring(n) .. ")")
    check(#removedIds == 2 and removedIds[1] == 1 and removedIds[2] == 3,
        "removes only vacant AV ids (got " .. table.concat(removedIds, ",") .. ")")
    check(still == 0, "no within-grace on a forced sweep")
    check(state[1] == nil and state[3] == nil, "removed AVs leave no grace state")
    check(state[2] == nil and state[4] == nil and state[5] == nil,
        "non-candidates never enter grace state")
end)

run("runSweep: grace arms, watches, then removes", function()
    local state = {}
    -- Sweep 1: fresh vacant AV -> arms the timer.
    local n1, still1 = S.runSweep({ vehicle(1, "Vehicle.av_militech_manticore") },
        state, 1000, 5, false, function() return true end)
    check(n1 == 0 and still1 == 0, "sweep 1 removes nothing and counts nothing")
    check(state[1] == 1000, "sweep 1 arms the timer (state=" .. tostring(state[1]) .. ")")
    -- Sweep 2: 2 minutes later -> still within grace.
    local n2, still2 = S.runSweep({ vehicle(1, "Vehicle.av_militech_manticore") },
        state, 1002, 5, false, function() return true end)
    check(n2 == 0 and still2 == 1, "sweep 2 watches within grace")
    check(state[1] == 1000, "sweep 2 does not re-arm (state=" .. tostring(state[1]) .. ")")
    -- Sweep 3: 6 minutes later -> removed, age reported as 6.
    local n3, still3, info3 = S.runSweep({ vehicle(1, "Vehicle.av_militech_manticore") },
        state, 1006, 5, false, function() return true end)
    check(n3 == 1 and still3 == 0, "sweep 3 removes past grace")
    check(info3[1] ~= nil and info3[1].id == 1 and info3[1].age == 6,
        "removal info carries id + vacantFor age (got "
        .. tostring(info3[1] and info3[1].age) .. ")")
    check(state[1] == nil, "state cleared after removal")
end)

run("runSweep: lease guard survives a forced sweep", function()
    local state = {}
    local removed = {}
    local n = S.runSweep({ vehicle(1, "Vehicle.av_militech_manticore", {}, 77) },
        state, 1000, 5, true, function(id) removed[#removed + 1] = id return true end)
    check(n == 0 and #removed == 0, "leased AV survives even a forced sweep")
    check(state[1] == nil, "leased AV leaves no grace state")
end)

run("runSweep: occupant guard survives a forced sweep", function()
    local state = {}
    local n = S.runSweep({ vehicle(1, "Vehicle.av_militech_manticore", { 5 }) },
        state, 1000, 5, true, function() return true end)
    check(n == 0, "occupied AV survives even a forced sweep")
end)

run("runSweep: failed removal clears state like production", function()
    local state = {}
    S.runSweep({ vehicle(1, "Vehicle.av_militech_manticore") },
        state, 1000, 5, false, function() return true end) -- arm
    local n, still, info = S.runSweep({ vehicle(1, "Vehicle.av_militech_manticore") },
        state, 1006, 5, false, function() return false end) -- removal call fails
    check(n == 0 and #info == 0, "failed removal is not counted as removed")
    check(state[1] == nil, "state cleared even when removal fails (matches production)")
end)

run("runSweep: forgets vehicles that vanished", function()
    local state = {}
    S.runSweep({ vehicle(1, "Vehicle.av_militech_manticore") },
        state, 1000, 5, false, function() return true end) -- arm AV 1
    S.runSweep({ vehicle(2, "Vehicle.av_rayfield_excalibur") },
        state, 1001, 5, false, function() return true end) -- AV 1 gone, AV 2 armed
    check(state[1] == nil, "vanished AV forgotten from grace state")
    check(state[2] == 1001, "new AV armed (state=" .. tostring(state[2]) .. ")")
end)

run("runSweep: empty world is a no-op", function()
    local state = {}
    local n, still = S.runSweep({}, state, 1000, 5, true, function() return true end)
    check(n == 0 and still == 0, "empty world removes nothing")
    check(next(state) == nil, "empty world leaves no state")
end)

-- ---------------------------------------------------------------------------
-- Result contract for the C# host.
-- ---------------------------------------------------------------------------
TestResult = { passed = passed, failed = #failures, failures = failures }

print(string.format("[open77_avcleanup tests] %d passed, %d failed", passed, #failures))
for _, f in ipairs(failures) do
    print("  FAIL: " .. f)
end
if #failures > 0 and os ~= nil and os.exit ~= nil then
    os.exit(1)
end