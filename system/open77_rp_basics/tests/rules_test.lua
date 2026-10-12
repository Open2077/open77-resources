-- =============================================================================
-- open77_rp_basics -- tests/rules_test.lua
-- =============================================================================
-- Unit tests for shared/rules.lua: the verb catalogue, argument shapes, the
-- precondition gate, the escort tether and the claim ledger.
--
-- Runs two ways:
--   * In the C# suite: Open77.Server.Tests.Resources.RpBasicsRulesTests loads
--     shared/rules.lua first (it sets the RpBasicsRules global) and then runs
--     this file, asserting on the TestResult global below.
--   * Standalone:  lua tests/rules_test.lua   (needs Lua 5.4; the file loads
--     shared/rules.lua itself when RpBasicsRules is not set).
-- =============================================================================

local R = RpBasicsRules
if R == nil then
    local chunk = loadfile("shared/rules.lua") -- standalone only
    assert(chunk, "shared/rules.lua not found -- run from the resource dir")
    R = chunk()
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

local CONFIG = R.config(nil)

-- A `Open77.players.get`-shaped read, with the fields the gate actually uses.
-- `ABSENT` removes a field: `{ alive = ABSENT }` in a table literal is not an
-- override, it is a key that was never written, which would silently make the
-- "an absent field is refused" cases test nothing at all.
local ABSENT = setmetatable({}, { __tostring = function() return "<absent>" end })

local function read(id, x, y, z, overrides)
    local value = {
        playerId = id,
        bucket = 0,
        ready = true,
        fresh = true,
        ageMs = 50,
        alive = true,
        position = { x = x, y = y, z = z },
    }
    for key, item in pairs(overrides or {}) do
        -- Spelled out rather than `(item ~= ABSENT) and item or nil`, which
        -- silently turns an override of `false` into an absent key.
        if item == ABSENT then value[key] = nil else value[key] = item end
    end
    return value
end

-- ---------------------------------------------------------------------------
-- The verb catalogue
-- ---------------------------------------------------------------------------
run("verbs", function()
    check(R.verbs.cuff.supported == true, "cuff is supported")
    check(R.verbs.escort.supported == true, "escort is supported")
    check(R.verbs.search.supported == true, "search is supported")

    -- The whole point of shipping carry as a refusal rather than omitting it.
    check(R.verbs.carry.supported == false, "carry is NOT supported on 2.31")
    check(R.verbs.carry.reason == "carry_unsupported", "carry refuses by name")

    check(R.verbs.cuff.holds == true, "a cuff is a standing hold")
    check(R.verbs.escort.holds == true, "an escort is a standing hold")
    check(R.verbs.search.holds == false, "a search ends on its own")

    for _, id in ipairs(R.verbOrder) do
        check(R.verbs[id] ~= nil, "verbOrder names a real verb: " .. id)
        check(type(R.verbs[id].permission) == "string", id .. " names an ACL permission")
    end

    local caps = R.capabilities()
    check(#caps == #R.verbOrder, "capabilities() lists every verb")
    local carry
    for _, row in ipairs(caps) do if row.verb == "carry" then carry = row end end
    check(carry ~= nil and carry.supported == false and carry.reason == "carry_unsupported",
        "capabilities() reports carry as unsupported, with the reason")
end)

-- ---------------------------------------------------------------------------
-- Argument shapes
-- ---------------------------------------------------------------------------
run("playerId", function()
    check(R.playerId(1) == 1, "1 is a player id")
    check(R.playerId("7") == 7, "a numeric string is a player id")
    check(R.playerId(0) == nil, "0 is NOT a player id (it is the console)")
    check(R.playerId(-3) == nil, "a negative id is refused")
    check(R.playerId(1.5) == nil, "a fractional id is refused")
    check(R.playerId(nil) == nil, "nil is refused")
    check(R.playerId("kevin") == nil, "a name is refused")
    check(R.playerId(2147483648) == nil, "an oversized id is refused")

    check(R.actorId(0) == 0, "0 IS an actor: the server console")
    check(R.actorId(-1) == nil, "a negative actor is refused")
end)

run("config", function()
    local tuned = R.config({ maxDistance = 5.0, maxHoldMs = 1000 })
    check(tuned.maxDistance == 5.0, "an override lands")
    check(tuned.maxHoldMs == 1000, "a second override lands")
    check(tuned.searchMs == R.defaults.searchMs, "an untouched key keeps its default")

    local rejected = R.config({ maxDistance = -1, tetherDistance = 0, searchMs = 0 / 0, nonsense = 5 })
    check(rejected.maxDistance == R.defaults.maxDistance, "a negative override is ignored")
    check(rejected.tetherDistance == R.defaults.tetherDistance, "a zero override is ignored")
    check(rejected.searchMs == R.defaults.searchMs, "a NaN override is ignored")
    check(rejected.nonsense == nil, "an unknown key is not adopted")
end)

run("distance", function()
    check(R.distance({ x = 0, y = 0, z = 0 }, { x = 3, y = 4, z = 0 }) == 5, "3-4-5")
    check(R.distance({ x = 0, y = 0, z = 0 }, { x = 0, y = 0, z = 0 }) == 0, "same point")
    check(R.distance(nil, { x = 0, y = 0, z = 0 }) == nil, "nil is not a point")
    check(R.distance({ x = 0, y = 0 }, { x = 0, y = 0, z = 0 }) == nil, "a missing axis is not a point")
end)

-- ---------------------------------------------------------------------------
-- The gate
-- ---------------------------------------------------------------------------
run("gate accepts", function()
    local ok, metres = R.gate("cuff", read(1, 0, 0, 0), read(2, 1, 0, 0), nil, CONFIG)
    check(ok == true, "an officer one metre away may cuff")
    check(math.abs(metres - 1.0) < 0.001, "the gate returns the measured distance")
end)

run("gate refuses", function()
    local function why(verb, officer, target, held)
        local ok, reason = R.gate(verb, officer, target, held, CONFIG)
        if ok then return "accepted" end
        return reason
    end

    check(why("fly", read(1, 0, 0, 0), read(2, 1, 0, 0)) == "unknown_verb", "unknown verb")
    check(why("carry", read(1, 0, 0, 0), read(2, 1, 0, 0)) == "carry_unsupported",
        "the gate refuses carry by name, before any world check")
    check(why("cuff", read(1, 0, 0, 0), read(1, 0, 0, 0)) == "cannot_target_self", "self")
    check(why("cuff", nil, read(2, 1, 0, 0)) == "invalid_player", "no officer")
    check(why("cuff", read(1, 0, 0, 0), read(2, 9, 0, 0)) == "too_far", "nine metres is too far")

    check(why("cuff", read(1, 0, 0, 0, { alive = false }), read(2, 1, 0, 0)) == "officer_not_alive",
        "a dead officer cuffs nobody")
    check(why("cuff", read(1, 0, 0, 0), read(2, 1, 0, 0, { alive = false })) == "target_not_alive",
        "a dead target is not cuffed -- acting on him is what crashes his client")
    check(why("cuff", read(1, 0, 0, 0), read(2, 1, 0, 0, { alive = ABSENT })) == "target_not_alive",
        "an ABSENT alive field is refused, not assumed true")

    check(why("cuff", read(1, 0, 0, 0), read(2, 1, 0, 0, { ready = false })) == "target_not_ready",
        "the join gate is still closed")
    check(why("cuff", read(1, 0, 0, 0), read(2, 1, 0, 0, { ageMs = 9000 })) == "target_position_stale",
        "a nine-second-old position is not evidence")
    check(why("cuff", read(1, 0, 0, 0), read(2, 1, 0, 0, { ageMs = ABSENT })) == "target_position_stale",
        "a player who has never reported has no position to check")
    check(why("cuff", read(1, 0, 0, 0), read(2, 1, 0, 0, { position = ABSENT })) == "target_no_position",
        "no position at all")
    check(why("cuff", read(1, 0, 0, 0), read(2, 1, 0, 0, { bucket = 4 })) == "different_bucket",
        "another world")

    local mine = { target = 2, officer = 1, verb = "cuff" }
    local theirs = { target = 2, officer = 9, verb = "cuff" }
    check(why("cuff", read(1, 0, 0, 0), read(2, 1, 0, 0), mine) == "already_held",
        "the same officer re-cuffing is told so")
    check(why("cuff", read(1, 0, 0, 0), read(2, 1, 0, 0), theirs) == "held_by_another",
        "two resources must not fight over one body")
    check(why("escort", read(1, 0, 0, 0), read(2, 1, 0, 0), mine) == "accepted",
        "the officer holding the cuff may upgrade it to an escort")
    check(why("escort", read(1, 0, 0, 0), read(2, 1, 0, 0), theirs) == "held_by_another",
        "somebody else's cuff is not upgradeable")
end)

-- ---------------------------------------------------------------------------
-- The tether
-- ---------------------------------------------------------------------------
run("tether", function()
    local state = { lastPullMs = -math.huge, pullPending = false }

    local action = R.tether(read(1, 0, 0, 0), read(2, 2, 0, 0), state, 10000, CONFIG)
    check(action == "none", "inside the radius, nothing happens")

    local point
    action, point = R.tether(read(1, 0, 0, 0), read(2, 20, 0, 0), state, 10000, CONFIG)
    check(action == "pull", "outside the radius, he is pulled back")
    check(type(point) == "table", "the pull carries a point")
    local back = R.distance({ x = 0, y = 0, z = 0 }, point)
    check(math.abs(back - CONFIG.tetherPullDistance) < 0.001,
        "the pull lands tetherPullDistance from the officer, on his side of the gap")
    check(point.z == 0, "the pull keeps the officer's height, not the runaway's")

    -- The cooldown is what stops a teleport starting before the last settled.
    action = R.tether(read(1, 0, 0, 0), read(2, 20, 0, 0), { lastPullMs = 9500 }, 10000, CONFIG)
    check(action == "none", "a pull 500 ms after the last one is held back")
    action = R.tether(read(1, 0, 0, 0), read(2, 20, 0, 0), { lastPullMs = 1000 }, 10000, CONFIG)
    check(action == "pull", "a pull 9 s after the last one goes ahead")
    action = R.tether(read(1, 0, 0, 0), read(2, 20, 0, 0),
        { lastPullMs = -math.huge, pullPending = true }, 10000, CONFIG)
    check(action == "none", "a pull already in flight is not doubled")

    -- Staleness pauses the leash; it never ends a hold.
    action = R.tether(read(1, 0, 0, 0), read(2, 20, 0, 0, { ageMs = 9000 }), state, 10000, CONFIG)
    check(action == "none", "a stale target is not pulled on")

    local reason
    action, reason = R.tether(read(1, 0, 0, 0, { alive = false }), read(2, 2, 0, 0), state, 10000, CONFIG)
    check(action == "end" and reason == "officer_dead", "a dead escort ends the hold")
    action, reason = R.tether(read(1, 0, 0, 0), read(2, 2, 0, 0, { alive = false }), state, 10000, CONFIG)
    check(action == "end" and reason == "target_dead", "a dead target ends the hold")
    action, reason = R.tether(read(1, 0, 0, 0), read(2, 2, 0, 0, { bucket = 3 }), state, 10000, CONFIG)
    check(action == "end" and reason == "target_bucket_changed", "another world ends the hold")
    action, reason = R.tether(read(1, 0, 0, 0), read(2, 2, 0, 0, { inVehicle = true }), state, 10000, CONFIG)
    check(action == "end" and reason == "target_mounted",
        "a seated body cannot be teleported, so the leash admits it holds nothing")

    for _, ending in ipairs({ "officer_dead", "target_dead", "target_bucket_changed", "target_mounted" }) do
        check(R.isEndReason(ending), "the tether only ever returns a declared end reason: " .. ending)
    end
end)

-- ---------------------------------------------------------------------------
-- The ledger
-- ---------------------------------------------------------------------------
run("ledger", function()
    local ledger = R.newLedger()
    check(ledger.count == 0, "a new ledger is empty")
    check(ledger:get(2) == nil, "nothing is held")

    local record, previous = ledger:claim({ target = 2, officer = 1, verb = "cuff", expiresAt = 100 })
    check(record ~= nil and previous == nil, "the first claim has no predecessor")
    check(ledger.count == 1, "one record")
    check(ledger:get(2).officer == 1, "the record is readable by target")
    check(record.claims ~= nil, "a record always carries a claims table")

    local _, replaced = ledger:claim({ target = 2, officer = 1, verb = "escort", expiresAt = 200 })
    check(replaced ~= nil and replaced.verb == "cuff", "re-claiming hands back the record it replaced")
    check(ledger.count == 1, "re-claiming does not double-count")

    ledger:claim({ target = 3, officer = 1, verb = "cuff", expiresAt = 50 })
    ledger:claim({ target = 4, officer = 9, verb = "cuff", expiresAt = 50 })
    check(#ledger:byOfficer(1) == 2, "an officer's own holds are findable")
    check(#ledger:byOfficer(9) == 1, "and only his own")
    check(#ledger:all() == 3, "all() sees everything")

    local expired = ledger:expired(100)
    check(#expired == 2, "two records are past their deadline at t=100")
    check(expired[1].expiresAt <= expired[2].expiresAt, "expired() is ordered oldest first")

    check(ledger:release(3) ~= nil, "releasing hands back the record")
    check(ledger:release(3) == nil, "releasing twice is not an error, it is nothing")
    check(ledger.count == 2, "the count follows")

    check(ledger:claim({ target = 0, officer = 1, verb = "cuff" }) == nil, "the console is not a target")
    check(ledger:claim({ target = 2, officer = 1, verb = "fly" }) == nil, "an unknown verb is not claimable")
end)

-- ---------------------------------------------------------------------------
-- The end-reason vocabulary
-- ---------------------------------------------------------------------------
run("endReasons", function()
    local seen = {}
    for _, reason in ipairs(R.endReasons) do
        check(seen[reason] == nil, "no duplicate end reason: " .. reason)
        seen[reason] = true
        check(R.isEndReason(reason), "isEndReason agrees: " .. reason)
        check(reason:match("^[a-z][a-z_]*$") ~= nil, "end reasons are snake_case: " .. reason)
    end
    check(R.isEndReason("whatever") == false, "an invented reason is not an end reason")
    check(R.isEndReason(nil) == false, "nil is not an end reason")

    -- Every party's departure must be covered on both sides of the hold.
    for _, required in ipairs({
        "released", "expired", "freed_by_admin",
        "officer_left", "officer_dead", "officer_bucket_changed",
        "target_left", "target_dead", "target_bucket_changed",
        "target_mounted", "resource_stopping", "superseded",
    }) do
        check(seen[required] == true, "the enumeration still covers " .. required)
    end
end)

run("publicRecord", function()
    local public = R.publicRecord({
        target = 2, officer = 1, verb = "cuff", since = 10, expiresAt = 20,
        owner = "open77_rp_basics", claims = { freeze = true },
    })
    check(public.target == 2 and public.officer == 1 and public.verb == "cuff", "the public fields survive")
    check(public.claims == nil, "the claims table never leaves the resource")
    check(R.publicRecord(nil) == nil, "nil in, nil out")
end)

TestResult = { passed = passed, failed = #failures, failures = failures }

if #failures > 0 then
    for _, failure in ipairs(failures) do print("FAIL: " .. failure) end
else
    print(("open77_rp_basics rules: %d assertions passed"):format(passed))
end
