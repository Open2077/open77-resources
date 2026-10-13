-- =============================================================================
-- open77_actions -- tests/lifecycle_test.lua
-- =============================================================================
-- Drives the REAL server half against tests/fakes.lua: the happy path, every
-- validation refusal, every cancellation path, claim contention, stale
-- completions, commit failure / in-doubt / retry, eligibility and epoch guards.
-- The invariant asserted after each case: the operation reached exactly one
-- terminal state and gave back every claim and animation it took.
--
-- Load order: tests/fakes.lua, shared/model.lua, server/claims.lua,
-- server/engine.lua, server/carry.lua, server/main.lua, this file.
-- =============================================================================

local F = Open77ActionsFakes
local R = Open77ActionsRuntime
assert(F ~= nil and R ~= nil, "fakes and server/main.lua must load first")
local E = R.engine
local M = Open77ActionsModel

local passed, failures = 0, {}
local function check(cond, msg)
    if cond then passed = passed + 1 else failures[#failures + 1] = msg or "assertion failed" end
end
local function run(name, fn)
    local ok, err = pcall(fn)
    if not ok then failures[#failures + 1] = name .. ": runtime error: " .. tostring(err) end
end

local JOB = "job"
F.generations[JOB] = 3
F.generations.other = 4
F.generations.rp_jobs = 5

-- --- the author resource ("job") and its hooks, as exports -----------------
local calls, behaviour
local function resetHooks()
    calls = { validate = {}, reserve = {}, commit = {}, cancel = {}, eligible = 0 }
    behaviour = {
        validate = function() return true end,
        reserve = function(ctx) return { held = "tx:" .. ctx.opId } end,
        commit = function(ctx) return { receipt = "r:" .. ctx.opId } end,
        eligible = function() return true end,
        epochs = {},
    }
end
resetHooks()

F.exportHandlers[JOB] = {
    v = function(ctx) calls.validate[#calls.validate + 1] = ctx; return behaviour.validate(ctx) end,
    r = function(ctx) calls.reserve[#calls.reserve + 1] = ctx; return behaviour.reserve(ctx) end,
    c = function(ctx)
        calls.commit[#calls.commit + 1] = ctx
        -- What a real commit hook does first: ask the library whether this is
        -- really one of ours, in the committing state.
        local ok = F.exports.verify and (function()
            F.invoker = JOB
            local v = F.exports.verify(ctx.opId, "commit")
            return v
        end)()
        ctx.verified = ok
        return behaviour.commit(ctx)
    end,
    x = function(ctx) calls.cancel[#calls.cancel + 1] = ctx; return true end,
}
F.exportHandlers.rp_jobs = {
    eligible = function(pid, args) calls.eligible = calls.eligible + 1; return behaviour.eligible(pid, args) end,
    workEpoch = function(pid) return behaviour.epochs[pid] or 0 end,
}

local function define(overrides)
    local def = {
        id = "weld", label = "Weld", durationMs = 2000, maxDistance = 2.5,
        animation = { profile = "amb_1056d7_kneel_welder", at = "target" },
        progress = { label = "Welding" },
        hooks = { validate = "v", commit = "c", cancel = "x" },
    }
    for k, v in pairs(overrides or {}) do
        if v == false and k ~= "progress" and k ~= "animation" and k ~= "claims" then def[k] = nil else def[k] = v end
    end
    local key, why = F.call(JOB, "define", def)
    assert(key, "define failed: " .. tostring(why))
    return key
end

local function target(id, position, actions)
    local key, why = F.call(JOB, "target", { id = id or "node1", position = position or { x = 1, y = 0, z = 0 },
        bucket = 0, actions = actions or { "weld" } })
    assert(key, "target failed: " .. tostring(why))
    return key
end

local function request(pid, action, targetRef, options)
    return F.call(JOB, "request", pid, action or "weld", targetRef == nil and "node1" or targetRef, options)
end

local function world()
    for _, op in pairs(E.ops) do
        if not M.TERMINAL[op.state] or op.trailing then E:cancel(op, "cancelled", "cancel") end
    end
    F.run()
    E.ops, E.opOrder, E.active, E.byPlayback, E.cooldowns, E.epochs = {}, {}, {}, {}, {}, {}
    E:undefine(JOB); E:removeTargets(JOB)
    E.claims = Open77ActionsClaims.new({ now = E.P.now })
    F.generations[JOB] = 3
    E.owners[JOB] = nil
    F.players, F.anim, F.vehicles = {}, {}, {}
    F.deferred = {}
    F.animRefuse = nil
    for _, line in ipairs(F.logs) do
        if line:find("sweep raised", 1, true) then F.threadErrors[#F.threadErrors + 1] = line end
    end
    F.reset()
    resetHooks()
    F.now = F.now + 10000
    F.player(1, 0, 0, 0)
    F.player(2, 0, 1, 0)
    define()
    target()
end

local function released(pid)
    return E.claims:count() == 0 and F.anim[pid] == nil and E.active[pid] == nil
end

local function stateOf(op) return E.ops[op.opId] and E.ops[op.opId].state end

-- ---------------------------------------------------------------------------
-- Happy path
-- ---------------------------------------------------------------------------
run("happy path: validate, present, server-clock completion, commit, projection", function()
    world()
    local op, why = request(1)
    check(op ~= nil and op.state == "presenting", "request starts presenting: " .. tostring(why))
    check(op and op.opId:match("^act%-") ~= nil and #op.opId >= 8, "opId is coordinator-compatible (>= 8 chars)")
    check(op and op.playbackId ~= nil and F.anim[1] and F.anim[1].kind == "playAt", "playAt at the target")
    check(E.claims:count() == 1, "the target is claimed")
    local present = F.lastClient("open77:actions:present", 1)
    check(present and present.payload.opId == op.opId and present.payload.generation == 7,
        "client told to present with opId and generation")
    check(present and present.payload.claims.move == true and present.payload.claims.attack == true,
        "default control claims: Movement and Attack")
    check(#calls.validate == 1 and calls.validate[1].phase == "begin", "validate hook asked at begin")
    F.advance(1500)
    check(stateOf(op) == "presenting" and #calls.commit == 0, "not complete before the server clock says so")
    F.advance(700)
    check(stateOf(op) == "committed", "committed after durationMs")
    check(#calls.commit == 1 and calls.commit[1].opId == op.opId and calls.commit[1].phase == "commit",
        "commit hook called once with the opId")
    check(calls.commit[1].verified == true, "verify() confirms the op to its owner during commit")
    check(#calls.validate == 2 and calls.validate[2].phase == "complete", "validate hook re-asked before commit")
    check(released(1), "claims, animation and active slot released")
    local ended = F.lastClient("open77:actions:end", 1)
    check(ended and ended.payload.opId == op.opId and ended.payload.state == "committed", "client told the end")
    check(E.ops[op.opId].receipt and E.ops[op.opId].receipt.receipt == "r:" .. op.opId, "receipt kept")
    local t = table.concat(F.transitions(op.opId), ",")
    check(t == "validating:nil,presenting:nil,committing:nil,committed:ok", "transition order: " .. t)
    check(#calls.cancel == 0, "no cancel hook on success")
end)

run("player intent: only actions the target offers", function()
    world()
    F.net("open77:actions:intent", 1, "job:weld", "job:node1")
    check(E.active[1] ~= nil and E.active[1].initiator == "player", "intent starts the action")
    world()
    define({ id = "secret" })
    F.net("open77:actions:intent", 1, "job:secret", "job:node1")
    check(E.active[1] == nil, "an action the target does not offer is refused")
    local refused = F.lastClient("open77:actions:refused", 1)
    check(refused and refused.payload.reason == "invalid_target", "refusal told to the client: invalid_target")
end)

run("targets are pushed to players in the bucket", function()
    world()
    local push = F.lastClient("open77:actions:targets", 1)
    check(push and push.payload.upsert[1] and push.payload.upsert[1].key == "job:node1", "target pushed")
    check(push.payload.upsert[1].choices[1].action == "job:weld", "choice carries the qualified action")
    F.call(JOB, "untarget", "node1")
    push = F.lastClient("open77:actions:targets", 1)
    check(push and push.payload.remove[1] == "job:node1", "removal pushed")
end)

-- ---------------------------------------------------------------------------
-- Validation refusals: nothing is held after any of them
-- ---------------------------------------------------------------------------
run("validation refusals", function()
    local cases = {
        { "too_far", function() F.player(1, 10, 0, 0) end },
        { "wrong_bucket", function() F.player(1, 0, 0, 0, { bucket = 4 }) end },
        { "player_not_alive", function() F.player(1, 0, 0, 0, { alive = false }) end },
        { "player_not_ready", function() F.player(1, 0, 0, 0, { ready = false }) end },
        { "player_in_vehicle", function() F.player(1, 0, 0, 0, { inVehicle = true }) end },
        { "position_unavailable", function() F.player(1, 0, 0, 0, { position = false }) end },
        { "position_stale", function() F.player(1, 0, 0, 0, { ageMs = 9000 }) end },
        { "in_combat", function() F.player(1, 0, 0, 0, { flags = { combatValid = true, aiming = true } }) end },
        { "player_unavailable", function() F.players[1] = nil end },
        { "spot_taken", function() F.player(2, 1.3, 0.2, 0.9) end },
        { "off_duty", function() behaviour.validate = function() return false, "off_duty" end end },
        { "refused_by_owner", function() behaviour.validate = function() return false, "a sentence, not a token" end end },
    }
    for _, case in ipairs(cases) do
        world()
        case[2]()
        local op, why, info = request(1)
        check(op == nil and why == case[1], case[1] .. " refused: got " .. tostring(why))
        check(info and info.stage == "validate", case[1] .. " at stage validate")
        check(released(1), case[1] .. " holds nothing")
    end
    world()
    local _, why = request(1, "nope")
    check(why == "unknown_action", "unknown_action")
    _, why = request(1, "weld", "nowhere")
    check(why == "unknown_target", "unknown_target")
    _, why = request(1, 42)
    check(why == "invalid_action", "invalid_action")
    _, why = request(0)
    check(why == "invalid_player", "invalid_player")
    _, why = request(1, "weld", "node1", "not a table")
    check(why == "invalid_options", "invalid_options")
    _, why = request(1, "weld", false)
    check(why == "invalid_target", "an action that requires a target refuses none (invalid_target)")
    _, why = F.call("other", "request", 1, "job:weld", "job:node1")
    check(why == "not_owner", "another resource cannot start job's action")
    _, why = F.call(JOB, "define", { id = "bad:id", durationMs = 1000 })
    check(why == "invalid_definition", "invalid_definition")
    F.generations[JOB] = 0
    _, why = request(1)
    check(why == "owner_unavailable", "a stopped owner's action refuses owner_unavailable")
end)

run("a placed action waits for its stand point; an unplaced one does not", function()
    world()
    F.player(2, 1.5, 0.0, 0.0)                         -- 0.5 m off the point: beside it, not on it
    local op = request(1)
    check(op ~= nil, "a player beside the stand point does not block it")
    world()
    F.player(2, 1.0, 0.0, 0.0)
    local _, why = request(2)
    check(why == nil or why ~= "spot_taken", "the actor's own body never blocks its own spot")
    world()
    F.player(2, 1.0, 0.0, 3.0)                         -- a floor above
    op = request(1)
    check(op ~= nil, "someone a floor above does not block it")
    world()
    define({ id = "inspect", animation = { profile = "examine" } })
    target("node2", { x = 1, y = 0, z = 0 }, { "inspect" })
    F.player(2, 1.0, 0.0, 0.0)
    op = request(1, "inspect", "node2")
    check(op ~= nil, "an action played where the actor stands is not refused")
    world()
    local working = request(2)
    check(working ~= nil, "player 2 starts working the target")
    F.player(2, 1.0, 0.0, 0.0)                         -- placed on the stand point
    _, why = request(1)
    check(why == "target_claimed", "someone working the target answers target_claimed, not spot_taken: got " .. tostring(why))
    world()
    target("chair", { x = 1.3, y = 0.3, z = 0 }, { "weld" })   -- a second station 0.42 m from node1
    local lying = request(2, "weld", "chair")
    check(lying ~= nil and E.active[2] ~= nil, "player 2 is placed at the chair")
    F.run()
    F.player(2, 1.3, 0.3, 0.0)
    local op2 = request(1)
    check(op2 ~= nil, "a player anchored in a placed action at another target does not block the spot")
end)

run("eligibility provider (rp_jobs:eligible) is asked at begin and before commit", function()
    world()
    define({ eligibility = { resource = "rp_jobs", export = "eligible", args = { job = "ferrailleur", duty = true } } })
    behaviour.eligible = function(_, args) return args.job == "ferrailleur" end
    local op = request(1)
    check(op ~= nil and calls.eligible == 1, "eligible at begin")
    behaviour.eligible = function() return nil, "off_duty" end
    F.advance(2200)
    check(stateOf(op) == "cancelled" and E.ops[op.opId].reason == "off_duty", "provider reason at completion")
    check(#calls.commit == 0 and released(1), "nothing committed, everything released")
    world()
    define({ eligibility = { resource = "rp_jobs", export = "eligible" } })
    behaviour.eligible = function() return nil end
    local _, why = request(1)
    check(why == "not_eligible", "a bare nil answers not_eligible")
    world()
    define({ eligibility = { resource = "rp_jobs", export = "missing" } })
    _, why = request(1)
    check(why == "hook_failed", "a raising provider answers hook_failed")
end)

run("epoch guard: read export captured at begin, rechecked at commit", function()
    world()
    define({ epochs = { resource = "rp_jobs", read = "workEpoch" } })
    behaviour.epochs[1] = 4
    local op = request(1)
    check(op ~= nil, "begins")
    behaviour.epochs[1] = 5
    F.advance(2200)
    check(stateOf(op) == "cancelled" and E.ops[op.opId].reason == "stale_job_epoch", "stale_job_epoch at commit")
    check(#calls.commit == 0 and released(1), "no commit, released")
end)

run("epoch guard: the announcing event cancels at once", function()
    world()
    define({ epochs = { event = "rp_jobs:workEpoch" } })
    TriggerEvent("rp_jobs:workEpoch", 1, 2, "duty")
    local op = request(1)
    F.advance(300)
    TriggerEvent("rp_jobs:workEpoch", 2, 9, "grade")       -- another player's epoch: ignored
    check(stateOf(op) == "presenting", "another player's epoch changes nothing")
    TriggerEvent("rp_jobs:workEpoch", 1, 3, "duty")
    check(stateOf(op) == "cancelled" and E.ops[op.opId].reason == "stale_job_epoch", "cancelled by the event")
    check(released(1), "released")
end)

-- ---------------------------------------------------------------------------
-- Claims: one winner
-- ---------------------------------------------------------------------------
run("claim contention: one winner, explicit refusal, then the next one", function()
    world()
    local a = request(1)
    local b, why, info = request(2)
    check(a ~= nil and b == nil and why == "target_claimed", "second actor refused target_claimed")
    check(info and info.retryable == true and info.holder == a.opId, "refusal is retryable and names the holder")
    F.call(JOB, "cancel", a.opId)
    b = request(2)
    check(b ~= nil and b.state == "presenting", "after release the next actor wins")
end)

run("claim_lost when a claim lapses mid-action", function()
    world()
    define({ claimTtlMs = 1000, durationMs = 5000 })
    local op = request(1)
    F.advance(1200)
    check(stateOf(op) == "cancelled" and E.ops[op.opId].reason == "claim_lost", "claim_lost")
    check(released(1), "released")
end)

run("resource claims for other targets (B6 seats) share the namespace", function()
    world()
    local token = F.call("other", "claim", 0, "seat:bench1", 5000)
    check(type(token) == "string", "a resource can claim a key")
    local _, why = F.call(JOB, "claim", 0, "seat:bench1", 5000)
    check(why == "target_claimed", "a second resource is refused")
    local _, notMine = F.call(JOB, "releaseClaim", token)
    check(notMine == "not_owner", "only the owner releases")
    check(F.call("other", "releaseClaim", token) == true, "owner releases")
    local _, lost = F.call("other", "renewClaim", token)
    check(lost == "claim_lost", "a released claim is claim_lost")
end)

run("a resource that only claims loses its claims when it stops or reloads (B6 seats)", function()
    world()
    F.generations.seats = 4
    local a = F.call("seats", "claim", 0, "furniture:v:1", 60000)
    local b = F.call("seats", "claim", 0, "furniture:v:2", 60000)
    check(type(a) == "string" and type(b) == "string" and E.claims:count() == 2, "two claims")
    F.fire("onResourceStop", "seats")
    check(E.claims:count() == 0, "released when the owner stops")
    local c = F.call("seats", "claim", 0, "furniture:v:1", 60000)
    check(type(c) == "string", "claims again once restarted")
    F.generations.seats = 5          -- reloaded without a stop event reaching us
    F.advance(200)
    check(E.claims:count() == 0, "released when the owner's generation changes")
    F.generations.seats = nil
end)

-- ---------------------------------------------------------------------------
-- Cancellation paths
-- ---------------------------------------------------------------------------
local function cancelCase(name, expected, trigger, overrides)
    run("cancel: " .. name, function()
        world()
        if overrides then define(overrides) end
        local op = request(1)
        check(op ~= nil, name .. ": started")
        if op == nil then return end
        F.advance(300)
        trigger(op)
        F.advance(200)
        local record = E.ops[op.opId]
        check(record.state == "cancelled", name .. ": cancelled (got " .. tostring(record.state) .. ")")
        check(record.reason == expected, name .. ": reason " .. expected .. " (got " .. tostring(record.reason) .. ")")
        check(released(1), name .. ": claims, animation and slot released")
        check(#calls.commit == 0, name .. ": nothing committed")
        check(#calls.cancel == 1 and calls.cancel[1].reason == expected, name .. ": cancel hook told once")
        local ended = F.lastClient("open77:actions:end", 1)
        check(name == "disconnect" or (ended and ended.payload.opId == op.opId), name .. ": client told")
    end)
end

cancelCase("death", "dead", function() F.fire("onPlayerLifeStateChanged", "1", 9, "dead", "pvp_damage") end)
cancelCase("disconnect", "disconnected", function()
    F.players[1] = nil
    F.fire("onPlayerDisconnected", "1", "connection_closed")
end)
cancelCase("bucket change", "bucket_changed", function()
    F.players[1].bucket = 3
    F.fire("onPlayerBucketChange", "1", 0, 3)
end)
cancelCase("vehicle entry", "vehicle", function() F.fire("onPlayerEnteringVehicle", "1", 55, 0) end)
cancelCase("combat (snapshot flags)", "combat", function() F.players[1].flags.triggerDown = true end)
cancelCase("weapon drawn", "combat", function() F.fire("onPlayerWeaponChanged", "1", "1", "Items.Pistol", "true") end,
    { cancelOn = { weaponDrawn = true } })
cancelCase("moved too far", "moved", function() F.players[1].position = { x = 0, y = -1.5, z = 0 } end,
    { animation = false })
cancelCase("animation interrupted", "animation_interrupted", function(op)
    F.animEnded(1, op.playbackId, "interrupted")
end)
cancelCase("player cancel", "cancelled_by_player", function(op) F.net("open77:actions:cancel", 1, op.opId) end)
cancelCase("owner stop", "owner_stopped", function()
    F.generations[JOB] = 0
    F.fire("onResourceStop", JOB)
end)
cancelCase("resource stop", "resource_stopping", function() F.fire("onResourceStop", "open77_actions") end)
cancelCase("api cancel", "cancelled", function(op) F.call(JOB, "cancel", op.opId) end)

run("cancel: superseding action", function()
    world()
    define({ id = "inspect", supersede = true, durationMs = 3000 })
    target("node2", { x = 0, y = -1, z = 0 }, { "inspect" })
    local first = request(1)
    local busy, why = request(1, "weld", "node1")
    check(busy == nil and why == "actor_busy", "a non-superseding action is refused actor_busy")
    local second = request(1, "inspect", "node2")
    check(second ~= nil and stateOf(first) == "cancelled" and E.ops[first.opId].reason == "superseded",
        "the superseding action cancels the first with superseded")
    check(E.active[1] and E.active[1].opId == second.opId, "the new action is current")
    check(E.claims:count() == 1, "only the new claim remains")
end)

run("cancel: an owner reload is detected by the sweep", function()
    world()
    local op = request(1)
    F.generations[JOB] = 9
    F.advance(200)
    check(stateOf(op) == "cancelled" and E.ops[op.opId].reason == "owner_stopped", "generation change = owner_stopped")
    check(E.actions["job:weld"] == nil and E.targets["job:node1"] == nil, "definitions and targets of the old VM gone")
end)

run("cancel at completion: revalidation refuses", function()
    world()
    local op = request(1)
    F.advance(500)
    F.players[1].position = { x = 6, y = 0, z = 0 }   -- animation actions: no moved watchdog, but completion checks
    F.advance(1800)
    check(stateOf(op) == "cancelled" and E.ops[op.opId].reason == "too_far" and E.ops[op.opId].stage == "complete",
        "too_far at stage complete")
    check(#calls.commit == 0 and released(1), "no commit")
end)

run("a client cannot cancel another player's operation", function()
    world()
    local op = request(1)
    F.net("open77:actions:cancel", 2, op.opId)
    check(stateOf(op) == "presenting", "player 2's cancel for player 1's op is ignored")
    local ok, why = E:clientCancel(2, op.opId)
    check(ok == nil and why == "unknown_operation", "unknown_operation for a foreign opId")
end)

run("terminal operations refuse a second end", function()
    world()
    local op = request(1)
    F.call(JOB, "cancel", op.opId)
    local ok, why = F.call(JOB, "cancel", op.opId)
    check(ok == nil and why == "already_terminal", "already_terminal")
    local _, unknown = F.call(JOB, "cancel", "act-nope-1")
    check(unknown == "unknown_operation", "unknown_operation")
    local _, foreign = F.call("other", "cancel", op.opId)
    check(foreign == "not_owner", "not_owner for another resource")
end)

run("animation refused at presentation fails the operation and releases", function()
    world()
    F.animRefuse = "player_not_ready"
    local op, why, info = request(1)
    check(op == nil and why == "animation_refused" and info.stage == "present", "animation_refused")
    check(released(1), "released")
    check(#calls.cancel == 1, "cancel hook told")
end)

-- ---------------------------------------------------------------------------
-- Reserve hook, async begin, stale completion
-- ---------------------------------------------------------------------------
run("async reserve: begin waits for it and returns a typed result", function()
    world()
    define({ hooks = { validate = "v", reserve = "r", commit = "c", cancel = "x" } })
    F.deferred["job:r"] = true
    local answer, why
    CreateThread(function()
        F.invoker, F.invokerGen = JOB, 3
        answer, why = F.exports.begin(1, "weld", "node1")
    end)
    F.invoker = nil
    check(answer == nil and why == nil, "begin still waiting on the reservation")
    check(E.active[1] and E.active[1].state == "reserving", "operation reserving")
    F.resolvePending("job:r", { held = "tx:1" })
    F.advance(200)
    check(type(answer) == "table" and answer.state == "presenting", "typed result: presenting")
    check(E.active[1].reservation and E.active[1].reservation.held == "tx:1", "reservation kept for commit")
    F.advance(2200)
    check(stateOf(answer) == "committed" and calls.commit[1].reservation.held == "tx:1", "commit sees the reservation")
end)

run("async reserve refused: typed failure, nothing held", function()
    world()
    define({ hooks = { reserve = "r", commit = "c", cancel = "x" } })
    behaviour.reserve = function() return nil, "capacity_exceeded" end
    local op = request(1)
    F.advance(100)
    check(stateOf(op) == "failed" and E.ops[op.opId].reason == "capacity_exceeded", "failed: capacity_exceeded")
    check(released(1), "released")
end)

run("reserve_timeout", function()
    world()
    define({ hooks = { reserve = "r", cancel = "x" }, reserveTimeoutMs = 1000 })
    F.deferred["job:r"] = true
    local op = request(1)
    F.advance(1200)
    check(stateOf(op) == "cancelled" and E.ops[op.opId].reason == "reserve_timeout", "reserve_timeout")
    check(#calls.cancel == 0, "cancel hook waits for the reservation to answer")
    F.resolvePending("job:r", { held = "late" })
    F.run()
    check(#calls.cancel == 1 and calls.cancel[1].reservation and calls.cancel[1].reservation.held == "late",
        "late reservation released through the cancel hook")
end)

run("stale completion: a late reserve answer cannot touch the replacement", function()
    world()
    define({ hooks = { reserve = "r", commit = "c", cancel = "x" } })
    define({ id = "inspect" })
    target("node2", { x = 0, y = -1, z = 0 }, { "inspect" })
    F.deferred["job:r"] = true
    local first = request(1)
    check(stateOf(first) == "reserving", "first reserving")
    F.net("open77:actions:cancel", 1, first.opId)
    check(stateOf(first) == "cancelled", "player cancels while the reservation is in flight")
    local second = request(1, "inspect", "node2")
    check(second ~= nil and stateOf(second) == "presenting", "replacement presenting")
    F.resolvePending("job:r", { held = "old" })
    F.run()
    local current = E.active[1]
    check(current and current.opId == second.opId and current.reservation == nil, "replacement untouched")
    check(#calls.cancel == 1 and calls.cancel[1].opId == first.opId, "old reservation released via cancel hook")
    -- A stale animation notice and a stale client cancel for the first op:
    F.animEnded(1, "pb-from-the-first-op", "interrupted")
    F.net("open77:actions:cancel", 1, first.opId)
    check(stateOf(second) == "presenting", "stale notices for the first op change nothing")
    F.advance(2200)
    check(stateOf(second) == "committed", "replacement completes")
end)

run("stale completion: a replaced playback's end does not cancel the new op", function()
    world()
    define({ id = "inspect", supersede = true })
    target("node2", { x = 0, y = -1, z = 0 }, { "inspect" })
    local first = request(1)
    local oldPlayback = first.playbackId
    local second = request(1, "inspect", "node2")
    F.animEnded(1, oldPlayback, "replaced")
    check(stateOf(second) == "presenting", "replaced playback's end ignored")
end)

-- ---------------------------------------------------------------------------
-- Commit outcomes
-- ---------------------------------------------------------------------------
run("arrivalRadius: a target's radius reaches playAt, an action's own wins, out of range refused", function()
    world()
    local key = F.call(JOB, "target", { id = "grill", position = { x = 1, y = 0, z = 0 }, bucket = 0,
        actions = { "weld" }, arrivalRadius = 1.0 })
    check(key ~= nil, "target with arrivalRadius 1.0 accepted")
    local op = request(1, "weld", "grill")
    check(op ~= nil and op.state == "presenting", "presenting")
    check(F.anim[1] and F.anim[1].kind == "playAt" and F.anim[1].arrivalRadius == 1.0, "playAt got arrivalRadius 1.0")
    world()
    define({ id = "weld2", animation = { profile = "amb_1056d7_kneel_welder", at = "target", arrivalRadius = 1.2 } })
    F.call(JOB, "target", { id = "grill2", position = { x = 1, y = 0, z = 0 }, bucket = 0,
        actions = { "weld2" }, arrivalRadius = 0.7 })
    request(1, "weld2", "grill2")
    check(F.anim[1] and F.anim[1].arrivalRadius == 1.2, "the action's arrivalRadius wins over the target's")
    local bad, why = F.call(JOB, "target", { id = "grill3", position = { x = 1, y = 0, z = 0 }, bucket = 0,
        actions = { "weld" }, arrivalRadius = 2.0 })
    check(bad == nil and why == "invalid_target", "arrivalRadius 2.0 refused invalid_target")
end)

run("default choice keys: E, F, R, Y; never T (chat), G (put-down) or X (cancel)", function()
    world()
    for _, id in ipairs({ "k2", "k3", "k4" }) do define({ id = id }) end
    local key = F.call(JOB, "target", { id = "four", position = { x = 1, y = 0, z = 0 }, bucket = 0,
        actions = { "weld", "k2", "k3", "k4" } })
    check(key ~= nil, "a four-choice target")
    local keys = {}
    for _, choice in ipairs(E.targets[key].actions) do keys[#keys + 1] = choice.key end
    check(table.concat(keys, ",") == "E,F,R,Y", "keys " .. table.concat(keys, ","))
    for _, k in ipairs(M.CHOICE_KEYS) do check(k ~= "T" and k ~= "G" and k ~= "X", "no reserved default key: " .. k) end
end)

run("commit refused: failed with the hook's reason, cancel hook told", function()
    world()
    behaviour.commit = function() return nil, "capacity_exceeded" end
    local op = request(1)
    F.advance(2200)
    check(stateOf(op) == "failed" and E.ops[op.opId].reason == "capacity_exceeded" and E.ops[op.opId].stage == "commit",
        "failed: capacity_exceeded at commit")
    check(#calls.cancel == 1 and released(1), "cancel hook, released")
end)

run("commit in doubt: retried with the same opId, then in_doubt", function()
    world()
    behaviour.commit = function() return nil, "in_doubt" end
    local op = request(1)
    F.advance(2200)
    F.advance(3000)
    check(#calls.commit == 3, "commit tried 1 + 2 retries (got " .. #calls.commit .. ")")
    check(calls.commit[1].opId == calls.commit[3].opId, "same opId on every retry")
    check(stateOf(op) == "in_doubt", "in_doubt, never failed")
    check(#calls.cancel == 1 and released(1), "presentation and claims released")
end)

run("transient refusal: retried with the same opId, then failed (never in doubt)", function()
    world()
    behaviour.commit = function() return nil, "store_unavailable" end
    local op = request(1)
    F.advance(2200)
    F.advance(3000)
    check(#calls.commit == 3, "commit tried 1 + 2 retries (got " .. #calls.commit .. ")")
    check(calls.commit[1].opId == calls.commit[3].opId, "same opId on every retry")
    check(stateOf(op) == "failed" and E.ops[op.opId].reason == "store_unavailable", "failed: store_unavailable")
    check(#calls.cancel == 1 and released(1), "cancel hook, released")
end)

run("transient refusal then fenced: failed with the first reason", function()
    world()
    local tries = 0
    behaviour.commit = function()
        tries = tries + 1
        if tries == 1 then return nil, "store_unavailable" end
        return nil, "aborted"
    end
    local op = request(1)
    F.advance(2200)
    F.advance(1000)
    check(tries == 2, "one retry (got " .. tries .. ")")
    check(stateOf(op) == "failed" and E.ops[op.opId].reason == "store_unavailable", "failed: store_unavailable, not aborted")
end)

run("commit in doubt then replayed: committed", function()
    world()
    local tries = 0
    behaviour.commit = function(ctx)
        tries = tries + 1
        if tries == 1 then return nil, "export_timeout" end
        return { replay = true }
    end
    local op = request(1)
    F.advance(2200)
    F.advance(1000)
    check(stateOf(op) == "committed" and tries == 2, "second attempt commits")
end)

run("a cancel while committing does not undo the commit", function()
    world()
    F.deferred["job:c"] = true
    local op = request(1)
    F.advance(2200)
    check(stateOf(op) == "committing", "committing")
    local ok, why = F.call(JOB, "cancel", op.opId)
    check(ok == nil and why == "commit_in_flight", "cancel answers commit_in_flight")
    F.fire("onPlayerLifeStateChanged", "1", 9, "dead")
    F.resolvePending("job:c", { done = true })
    F.run()
    check(stateOf(op) == "committed", "the commit's answer decides: committed")
    check(released(1), "released")
end)

run("commit at a marker before the end: committed, presentation trails", function()
    world()
    define({ durationMs = 3000, commitAtMs = 1000, markers = { { name = "spark", atMs = 500 } } })
    local op = request(1)
    F.advance(1100)
    check(stateOf(op) == "committed", "committed at commitAtMs")
    check(F.anim[1] ~= nil and E.active[1] ~= nil and E.active[1].trailing, "animation still playing (trailing)")
    local marker = false
    for _, entry in ipairs(F.host) do
        if entry.name == "open77_actions:marker" and entry.args[1].marker == "spark" then marker = true end
    end
    check(marker, "marker event fired")
    F.fire("onPlayerLifeStateChanged", "1", 9, "dead")
    check(F.anim[1] == nil and E.active[1] == nil, "a death while trailing only cuts the frames")
    check(stateOf(op) == "committed", "still committed")
end)

run("cooldown after a commit", function()
    world()
    define({ cooldownMs = 5000 })
    local op = request(1)
    F.advance(2200)
    check(stateOf(op) == "committed", "committed")
    local again, why = request(1)
    check(again == nil and why == "actor_busy", "cooldown refuses actor_busy")
end)

run("status, current and verify", function()
    world()
    local op = request(1)
    local status = F.call(JOB, "status", op.opId)
    check(status and status.state == "presenting" and status.generation == 7, "status")
    local current = F.call(JOB, "current", 1)
    check(current and current.opId == op.opId, "current")
    local ok, why = F.call("other", "verify", op.opId, "commit")
    check(ok == false and why == "not_owner", "verify refuses a foreign resource")
    ok, why = F.call(JOB, "verify", op.opId, "commit")
    check(ok == false and why == "already_terminal", "verify refuses the wrong phase")
end)

run("hook_failed when a hook export is missing", function()
    world()
    define({ hooks = { validate = "nope" } })
    local _, why = request(1)
    check(why == "hook_failed", "hook_failed")
end)

run("every transition is one log line with op, state and reason", function()
    world()
    E.trace = true
    local op = request(1)
    F.advance(2200)
    E.trace = false
    local found = false
    for _, line in ipairs(F.logs) do
        if line:find("[actions] op=" .. op.opId .. " state=committed reason=ok", 1, true) then found = true end
    end
    check(found, "[actions] op=... state=committed reason=ok line")
end)

-- ---------------------------------------------------------------------------
-- The integrator's console path (lab mode)
-- ---------------------------------------------------------------------------
local function logged(pattern)
    for _, line in ipairs(F.logs) do if line:find(pattern) then return line end end
    for _, line in ipairs(F.prints) do if line:find(pattern) then return line end end
    return nil
end

run("lab commands drive an action end to end with explicit player ids", function()
    world()
    check(F.commands["actions.lab.node"] == nil, "lab commands absent until enabled")
    F.commands["actions.lab.enable"](0, {})
    check(F.commands["actions.lab.node"] ~= nil, "lab enabled from the console")
    F.commands["actions.lab.node"](0, { "1", "amb_1056d7_kneel_welder", "3000" })
    check(logged("%[actions%] lab target=open77_actions:lab_node_%d+") ~= nil, "node printed")
    local key = E.targets["open77_actions:lab_node_1"] and "lab_node_1" or nil
    check(key ~= nil, "lab target registered")
    F.player(2, 0, 20, 0)
    F.commands["actions.lab.begin"](0, { "2", key })
    check(logged("state=refused reason=too_far stage=validate") ~= nil, "a far player is refused: too_far")
    F.reset()
    F.commands["actions.lab.begin"](0, { "1", key })
    check(logged("op=act%-[%w%-]+ state=presenting reason=%- stage=present action=open77_actions:lab_work player=1") ~= nil,
        "[actions] op=... state=presenting line")
    F.player(2, 1.5, 0, 0)
    F.commands["actions.lab.begin"](0, { "2", key })
    check(logged("state=refused reason=target_claimed") ~= nil, "contention printed: target_claimed")
    F.advance(3200)
    check(logged("state=committed reason=ok") ~= nil, "committed line")
    F.reset()
    F.commands["actions.lab.commit"](0, { "fail", "capacity_exceeded" })
    F.commands["actions.lab.begin"](0, { "1", key })
    F.advance(3200)
    check(logged("state=failed reason=capacity_exceeded stage=commit") ~= nil, "lab commit failure path")
    F.commands["actions.lab.commit"](0, { "ok" })
    F.reset()
    F.commands["actions.lab.crate"](0, { "1", "crate.small", "700", "1200" })
    local itemLine = logged("%[actions%] lab item=")
    check(itemLine ~= nil and itemLine:find("gripMs=700 releaseMs=1200", 1, true) ~= nil, "crate placed with markers")
    local itemId = itemLine and itemLine:match("item=(%S+)")
    F.commands["actions.lab.pickup"](0, { "1", itemId })
    F.advance(1500)
    check(logged("phase=picked_up") ~= nil, "carry picked_up line")
    F.commands["actions.lab.putdown"](0, { "1", "ground" })
    F.advance(2500)
    check(logged("phase=put_down") ~= nil, "carry put_down line")
    F.commands["actions.lab.clear"](0, {})
    check(E.targets["open77_actions:lab_node_1"] == nil, "lab cleared")
    E.trace = false
end)

run("keepCrowdOff: the crowd is kept off the point while the target exists", function()
    world()
    local holds, releases = {}, {}
    F.exportHandlers.open77_pedestrians = {
        holdSeat = function(bucket, key, position, options)
            holds[#holds + 1] = { bucket = bucket, key = key, x = position.x, radius = options.radius,
                force = options.force }
            return true
        end,
        releaseSeat = function(bucket, key) releases[#releases + 1] = key; return true end,
    }
    local key = F.call(JOB, "target", { id = "bench", position = { x = 4, y = 0, z = 0 }, bucket = 0,
        actions = { "weld" }, keepCrowdOff = true })
    check(key == "job:bench", "a target that keeps the crowd off is accepted")
    check(#holds == 1 and holds[1].key == "act:job:bench" and holds[1].radius == 0.8 and holds[1].force == true,
        "the hold is taken at once (0.8 m, forced)")
    F.call(JOB, "untarget", "bench")
    check(#releases == 1 and releases[1] == "act:job:bench", "the hold is released with the target")
    local bad, why = F.call(JOB, "target", { id = "bad", position = { x = 4, y = 0, z = 0 }, bucket = 0,
        actions = { "weld" }, keepCrowdOff = 9 })
    check(bad == nil and why == "invalid_target", "a radius beyond 1.5 m is refused")
    F.exportHandlers.open77_pedestrians = nil
    local plain = F.call(JOB, "target", { id = "plain", position = { x = 4, y = 0, z = 0 }, bucket = 0,
        actions = { "weld" }, keepCrowdOff = true })
    check(plain == "job:plain", "without open77_pedestrians the target still works")
end)

run("promptAt: the card is drawn at another point than the stand point", function()
    world()
    local key = F.call(JOB, "target", { id = "station", position = { x = 1, y = 0, z = 0 }, bucket = 0,
        actions = { "weld" }, promptAt = { x = 1.4, y = 0.3, z = 0 } })
    check(key == "job:station", "a target with promptAt is accepted")
    local push = F.lastClient("open77:actions:targets", 1)
    local sent
    for _, t in ipairs(push and push.payload.upsert or {}) do if t.key == "job:station" then sent = t end end
    check(sent and sent.promptAt and sent.promptAt.x == 1.4 and sent.position.x == 1, "the client gets both points")
    local far, why = F.call(JOB, "target", { id = "far", position = { x = 1, y = 0, z = 0 }, bucket = 0,
        actions = { "weld" }, promptAt = { x = 5, y = 0, z = 0 } })
    check(far == nil and why == "invalid_target", "a card more than 3 m from its stand point is refused")
end)

run("messages: a definition rewords or silences what the player reads", function()
    world()
    define({ id = "secret", messages = { invalid_target = "Not at this bench." } })
    F.net("open77:actions:intent", 1, "job:secret", "job:node1")
    local refused = F.lastClient("open77:actions:refused", 1)
    check(refused and refused.payload.reason == "invalid_target" and refused.payload.message == "Not at this bench.",
        "a refusal carries the action's own text")
    world()
    define({ messages = { vehicle = false } })
    local op = request(1)
    check(op ~= nil, "started")
    F.advance(300)
    F.fire("onPlayerEnteringVehicle", "1", 55, 0)
    F.advance(200)
    local ended = F.lastClient("open77:actions:end", 1)
    check(ended and ended.payload.reason == "vehicle" and ended.payload.message == false,
        "a silenced stop reason reaches the client as false")
    world()
    local op2 = request(1)
    F.advance(300)
    F.fire("onPlayerEnteringVehicle", "1", 55, 0)
    F.advance(200)
    ended = F.lastClient("open77:actions:end", 1)
    check(op2 ~= nil and ended and ended.payload.message == nil, "no messages: the client's default text")
    local base = { id = "bad", label = "Bad", durationMs = 2000, hooks = { commit = "c" } }
    for _, messages in ipairs({ "text", { ["not a token"] = "x" }, { moved = 5 }, { moved = "two" .. string.char(10) .. "lines" },
        { moved = string.rep("x", 201) } }) do
        base.messages = messages
        local key, why = F.call(JOB, "define", base)
        check(key == nil and why == "invalid_definition", "malformed messages refused: " .. tostring(why))
    end
end)

run("no scheduled thread raised during the suite", function()
    local clean, detail = F.noThreadErrors()
    check(clean, "thread errors: " .. detail)
end)

TestResult = { passed = passed, failed = #failures, failures = failures }
