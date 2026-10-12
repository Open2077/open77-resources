-- =============================================================================
-- open77_rp_basics -- tests/server_test.lua
-- =============================================================================
-- Drives the real `server/main.lua` against `tests/fakes.lua` and asserts the
-- one property the kit exists to guarantee: **a hold releases exactly the
-- claims it took, on every path it can end on.**
--
-- There is one test per row of `Rules.endReasons`, plus the authority checks
-- that stop a griefer and the admin path that must work even when the resource
-- that cuffed somebody has stopped caring.
--
-- Load order: shared/rules.lua, tests/fakes.lua, server/main.lua, this file.
-- =============================================================================

local R = RpBasicsRules
local F = RpBasicsFakes
assert(R ~= nil, "shared/rules.lua did not load")
assert(F ~= nil, "tests/fakes.lua did not load")
assert(F.exports.cuff ~= nil, "server/main.lua did not load")

local passed, failures = 0, {}
local function check(cond, msg)
    if cond then passed = passed + 1 else failures[#failures + 1] = msg or "assertion failed" end
end

local function run(name, fn)
    local ok, err = pcall(fn)
    if not ok then failures[#failures + 1] = name .. ": runtime error: " .. tostring(err) end
end

local OFFICER, TARGET, STRANGER = 1, 2, 3

-- A clean world before every case: nobody held, nobody claimed, no history.
local function world()
    -- Release anything the previous case left standing, through the kit's own
    -- console path, so a leak in one test cannot be hidden by the next.
    for _, record in ipairs(F.exports.held()) do F.exports.release(record.target, 0) end
    F.tick()
    F.frozen, F.animations = {}, {}
    F.reset()
    F.now = F.now + 1000
    F.teleportResult = { true, nil }
    F.player(OFFICER, 0, 0, 0)
    F.player(TARGET, 1, 0, 0)
    F.player(STRANGER, 40, 0, 0)
    F.grant(OFFICER, "rp.cuff", "rp.escort", "rp.search")
end

local function releasedReasons()
    local out = {}
    for _, entry in ipairs(F.hostEventsNamed("open77_rp_basics:released")) do
        out[#out + 1] = entry.args[4]
    end
    return out
end

local function lastReleaseReason()
    local all = releasedReasons()
    return all[#all]
end

-- ---------------------------------------------------------------------------
-- The capability answer, and carry
-- ---------------------------------------------------------------------------
run("capabilities", function()
    world()
    local caps = F.exports.capabilities()
    check(type(caps) == "table" and #caps == 4, "capabilities lists four verbs")
    local ok, reason = F.exports.carry(OFFICER, TARGET)
    check(ok == false and reason == "carry_unsupported",
        "carry is present and refuses by name rather than pretending")
end)

-- ---------------------------------------------------------------------------
-- Authority
-- ---------------------------------------------------------------------------
run("authority", function()
    world()
    local ok, reason = F.exports.cuff(STRANGER, TARGET)
    check(ok == false and reason == "not_authorised",
        "a player without rp.cuff cuffs nobody -- this is what stops a griefer")
    check(F.nothingHeld(TARGET), "a refused cuff takes nothing")

    ok, reason = F.exports.cuff(OFFICER, TARGET)
    check(ok == true, "the officer with rp.cuff may cuff: " .. tostring(reason))

    -- The console is local administration and has no body to stand near.
    world()
    check(F.exports.cuff(0, TARGET) == true, "the server console may cuff without an ACL grant")
end)

run("distance and state gates surface through the export", function()
    world()
    F.player(TARGET, 40, 0, 0)
    local ok, reason = F.exports.cuff(OFFICER, TARGET)
    check(ok == false and reason == "too_far", "forty metres is refused, by name")

    world()
    F.player(TARGET, 1, 0, 0, { alive = false })
    ok, reason = F.exports.cuff(OFFICER, TARGET)
    check(ok == false and reason == "target_not_alive",
        "a dead target is refused: a server action on a client that is not alive crashes it")

    world()
    ok, reason = F.exports.cuff(OFFICER, OFFICER)
    check(ok == false and reason == "cannot_target_self", "nobody cuffs himself")
end)

-- ---------------------------------------------------------------------------
-- cuff: what it takes, and that release gives it all back
-- ---------------------------------------------------------------------------
run("cuff takes freeze, animation and the client block", function()
    world()
    check(F.exports.cuff(OFFICER, TARGET) == true, "cuffed")
    check(F.frozen[TARGET] == 1, "the body is frozen exactly once")
    check(F.animations[TARGET] ~= nil, "hands up")
    local wire = F.lastClientEvent(TARGET)
    check(wire ~= nil and wire.payload.mode == "cuff", "the target's client is told to block input")
    check(#F.hostEventsNamed("open77_rp_basics:held") == 1, "one held event")

    local record = F.exports.state(TARGET)
    check(record ~= nil and record.verb == "cuff" and record.officer == OFFICER, "state() reads back")
    check(record.claims == nil, "state() never leaks the claims table")
    check(#F.exports.held() == 1, "held() lists him")
end)

run("release gives back exactly what was taken", function()
    world()
    F.exports.cuff(OFFICER, TARGET)
    F.reset()

    local ok, reason = F.exports.release(TARGET, STRANGER)
    check(ok == false and reason == "not_authorised", "a bystander cannot free him")
    check(F.frozen[TARGET] == 1, "and nothing moved")

    check(F.exports.release(TARGET, OFFICER) == true, "the officer holding him can")
    check(F.frozen[TARGET] == 0, "the freeze claim came back")
    check(F.animations[TARGET] == nil, "the animation stopped")
    local wire = F.lastClientEvent(TARGET)
    check(wire ~= nil and wire.payload.mode == "free", "the client was told to release its block")
    check(lastReleaseReason() == "released", "the end reason is 'released'")
    check(F.exports.state(TARGET) == nil, "the ledger is empty")

    ok, reason = F.exports.release(TARGET, OFFICER)
    check(ok == false and reason == "not_held", "releasing twice says so instead of pretending")
end)

run("an admin can always free a cuffed player", function()
    world()
    F.grant(STRANGER, "rp.admin")
    F.exports.cuff(OFFICER, TARGET)
    F.reset()
    check(F.exports.release(TARGET, STRANGER) == true, "rp.admin frees anybody")
    check(lastReleaseReason() == "freed_by_admin", "and the reason says who did it")
    check(F.nothingHeld(TARGET), "with every claim returned")

    -- The console path, which works even when no admin is connected.
    world()
    F.exports.cuff(OFFICER, TARGET)
    F.reset()
    F.commands["rp.free"](0, { tostring(TARGET) })
    check(F.nothingHeld(TARGET), "rp.free from the console frees him too")
end)

-- ---------------------------------------------------------------------------
-- escort: the upgrade, and the tether
-- ---------------------------------------------------------------------------
run("escort replaces a cuff rather than stacking on it", function()
    world()
    F.exports.cuff(OFFICER, TARGET)
    F.reset()
    check(F.exports.escort(OFFICER, TARGET) == true, "the same officer may upgrade")
    check(F.frozen[TARGET] == 0, "the freeze was released: an escorted player walks himself")
    check(F.animations[TARGET] == nil, "and the stationary hands-up profile stopped -- walking cancels it")
    local wire = F.lastClientEvent(TARGET)
    check(wire ~= nil and wire.payload.mode == "escort", "the client switched to the walking block")
    check(lastReleaseReason() == "superseded", "the replaced hold ended with a named reason")
    check(#F.exports.held() == 1, "one body, one hold")

    -- Standing right there, so the refusal below is about the hold and not
    -- about the distance gate having fired first.
    F.player(STRANGER, 1, 1, 0)
    local ok, reason = F.exports.escort(STRANGER, TARGET)
    check(ok == false and reason == "not_authorised", "a stranger without rp.escort cannot take him")
    F.grant(STRANGER, "rp.escort")
    ok, reason = F.exports.escort(STRANGER, TARGET)
    check(ok == false and reason == "held_by_another",
        "and even with the grant he cannot take a body somebody else is holding")
end)

run("the tether pulls a runaway back, once per cooldown", function()
    world()
    F.exports.escort(OFFICER, TARGET)
    F.reset()

    F.player(TARGET, 2, 0, 0)
    F.tick()
    check(#F.teleports == 0, "inside the radius, nothing is teleported")

    F.player(TARGET, 30, 0, 0)
    F.tick()
    check(#F.teleports == 1, "outside the radius, he is pulled back")
    check(F.teleports[1].player == TARGET, "the target is the one moved, not the officer")

    F.tick()
    check(#F.teleports == 1, "a second pull inside the cooldown is held back")

    F.now = F.now + 5000
    F.tick()
    check(#F.teleports == 2, "past the cooldown it pulls again")
end)

run("a mounted target ends the escort instead of pretending to hold him", function()
    world()
    F.exports.escort(OFFICER, TARGET)
    F.reset()
    F.teleportResult = { false, "player_in_vehicle" }
    F.player(TARGET, 30, 0, 0)
    F.tick()
    check(lastReleaseReason() == "target_mounted",
        "the one teleport refusal that means the leash holds nothing ends the hold")
    check(F.exports.state(TARGET) == nil, "and the ledger is clear")
end)

-- ---------------------------------------------------------------------------
-- Every other way a hold ends
-- ---------------------------------------------------------------------------
local function endsWith(setup, expected, message)
    world()
    F.exports.cuff(OFFICER, TARGET)
    F.reset()
    setup()
    check(lastReleaseReason() == expected, message .. " (got " .. tostring(lastReleaseReason()) .. ")")
    check(F.nothingHeld(TARGET), message .. ": every claim came back")
    check(F.exports.state(TARGET) == nil, message .. ": the ledger is clear")
end

run("officer_left", function()
    endsWith(function() F.fire("onPlayerDisconnected", OFFICER, "connection_closed") end,
        "officer_left", "the officer disconnecting frees his prisoner")
end)

run("target_left", function()
    world()
    F.exports.cuff(OFFICER, TARGET)
    F.reset()
    F.fire("onPlayerDisconnected", TARGET, "connection_closed")
    check(lastReleaseReason() == "target_left", "the target disconnecting clears the record")
    check(F.exports.state(TARGET) == nil, "and the ledger with it")
end)

run("officer_dead", function()
    endsWith(function() F.fire("onPlayerLifeStateChanged", OFFICER, 4, "dead", "killed") end,
        "officer_dead", "a dead officer holds nobody")
end)

run("target_dead", function()
    endsWith(function() F.fire("onPlayerLifeStateChanged", TARGET, 4, "dead", "killed") end,
        "target_dead", "a dead target is not still cuffed")
end)

run("life state alive is not an ending", function()
    world()
    F.exports.cuff(OFFICER, TARGET)
    F.reset()
    F.fire("onPlayerLifeStateChanged", TARGET, 5, "alive", "restored")
    check(#releasedReasons() == 0, "a revive notification does not free him")
    check(F.exports.state(TARGET) ~= nil, "the hold stands")
end)

run("bucket changes", function()
    endsWith(function() F.fire("onPlayerBucketChange", TARGET, 4, 0) end,
        "target_bucket_changed", "a target in another world is not held here")
    endsWith(function() F.fire("onPlayerBucketChange", OFFICER, 4, 0) end,
        "officer_bucket_changed", "an officer in another world holds nobody here")
end)

run("expired", function()
    world()
    F.exports.cuff(OFFICER, TARGET, { holdMs = 5000 })
    local record = F.exports.state(TARGET)
    check(record.expiresAt - record.since == 5000, "holdMs shortens the deadline")
    F.reset()
    F.tick()
    check(F.exports.state(TARGET) ~= nil, "before the deadline he is still held")
    F.now = F.now + 6000
    F.tick()
    check(lastReleaseReason() == "expired",
        "the deadline is the backstop under every other path: nothing can strand a player")
    check(F.nothingHeld(TARGET), "with every claim returned")
end)

run("holdMs cannot lengthen a hold past the ceiling", function()
    world()
    F.exports.cuff(OFFICER, TARGET, { holdMs = 999999999 })
    local record = F.exports.state(TARGET)
    check(record.expiresAt - record.since == R.defaults.maxHoldMs,
        "an oversized request is clamped to the operator's ceiling")
end)

run("resource_stopping", function()
    world()
    F.player(STRANGER, 1, 1, 0)
    F.exports.cuff(OFFICER, TARGET)
    F.exports.cuff(OFFICER, STRANGER)
    F.reset()
    F.fire("onResourceStop", "somebody_else", "manual")
    check(#releasedReasons() == 0, "another resource stopping is not our business")
    F.fire("onResourceStop", "open77_rp_basics", "runtime_error")
    check(#releasedReasons() == 2, "our own stop frees everybody we held")
    check(F.nothingHeld(TARGET) and F.nothingHeld(STRANGER), "with every claim returned")
    for _, reason in ipairs(releasedReasons()) do
        check(reason == "resource_stopping", "named as a stop, not as an ordinary release")
    end
end)

-- ---------------------------------------------------------------------------
-- search
-- ---------------------------------------------------------------------------
run("search frisks, reports and lets go", function()
    world()
    local ticket = F.exports.search(OFFICER, TARGET)
    check(type(ticket) == "string", "search hands back a ticket")
    check(F.frozen[TARGET] == 1, "the frisk holds him still")
    check(F.animations[TARGET] ~= nil, "hands up for the frisk")

    F.tick()
    local reports = F.hostEventsNamed("open77_rp_basics:searched")
    check(#reports == 1, "one report")
    check(reports[1].args[3] == ticket, "the report carries the ticket the export returned")
    check(type(reports[1].args[4].weapons) == "table", "and what he is carrying")
    check(F.nothingHeld(TARGET), "the frisk gave back everything it took")
end)

run("a frisk and a cuff do not fight over one body", function()
    world()
    F.exports.cuff(OFFICER, TARGET)
    F.reset()
    local ticket = F.exports.search(OFFICER, TARGET)
    check(type(ticket) == "string", "a cuffed player can still be frisked")
    check(F.exports.state(TARGET) ~= nil, "and the cuff survives the frisk")
    check(F.exports.state(TARGET).verb == "cuff", "still a cuff, not replaced by the search")
    F.tick()
    check(F.exports.state(TARGET) ~= nil, "the cuff outlives the frisk")
    check(F.frozen[TARGET] == 1,
        "the frisk released ITS freeze and left the cuff's standing -- one claim each, released once each")
end)

run("two officers cannot frisk the same body at once", function()
    world()
    F.grant(STRANGER, "rp.search")
    F.player(STRANGER, 1, 1, 0)
    F.exports.search(OFFICER, TARGET)
    local ok, reason = F.exports.search(STRANGER, TARGET)
    check(ok == false and reason == "held_by_another", "the second frisk is refused")
    ok, reason = F.exports.search(OFFICER, TARGET)
    check(ok == false and reason == "already_held", "and so is the first officer asking twice")
    F.tick()
end)

-- ---------------------------------------------------------------------------
-- The client re-sync
-- ---------------------------------------------------------------------------
run("a client that reloaded gets its block back", function()
    world()
    F.exports.cuff(OFFICER, TARGET)
    F.reset()
    source = TARGET
    F.netHandlers["open77:rpbasics:sync"]()
    local wire = F.lastClientEvent(TARGET)
    check(wire ~= nil and wire.payload.mode == "cuff",
        "the server re-issues the standing hold, so a client reload does not free a prisoner")

    F.exports.release(TARGET, OFFICER)
    F.reset()
    source = TARGET
    F.netHandlers["open77:rpbasics:sync"]()
    wire = F.lastClientEvent(TARGET)
    check(wire ~= nil and wire.payload.mode == "free",
        "and tells a client with no hold to release whatever it is still holding")
    source = nil
end)

TestResult = { passed = passed, failed = #failures, failures = failures }

if #failures > 0 then
    for _, failure in ipairs(failures) do print("FAIL: " .. failure) end
else
    print(("open77_rp_basics server: %d assertions passed"):format(passed))
end
