-- =============================================================================
-- open77_seating -- tests/seating_test.lua
-- =============================================================================
-- The real server half against tests/fakes.lua: the happy path (validation,
-- claim, pedestrian hold, approach, playAt with the pose's arrival radius,
-- stand-up, exit), every refusal, player/player and player/NPC contention, a
-- bench row's alternate spot, every reconciliation path, dependency restarts,
-- a catalogue version change, the bounded prompts, /sit, the exports and the
-- lab console. Nothing here runs a game: these prove the bookkeeping, not the
-- presentation (docs/world-interaction/b6-seating.md has the live script).
-- =============================================================================

local F = Open77SeatingFakes
local M = Open77SeatingModel
local runtime = Open77SeatingRuntime
assert(F and M and runtime, "fakes, model and server/main.lua must load first")
local core, config = runtime.core, runtime.config

local passed, failures = 0, {}
local function check(cond, msg)
    if cond then passed = passed + 1 else failures[#failures + 1] = msg or "assertion failed" end
end
local function run(name, fn)
    local ok, err = pcall(fn)
    if not ok then failures[#failures + 1] = name .. ": runtime error: " .. tostring(err) end
    if #F.threadErrors > 0 then
        failures[#failures + 1] = name .. ": thread error: " .. table.concat(F.threadErrors, " | ")
        F.threadErrors = {}
    end
end

local VERSION = "furniture-1-test00000000"
local FURNITURE = {
    -- A: a measured chair 2 m north of the origin, facing +Y (its table).
    { poses = { { gid = "1001", x = 0, y = 2, z = 0, yaw = 0, kind = "chair", profile = "seated" } } },
    -- B: another chair 0.4 m from A, facing it (a crowded pair).
    { poses = { { gid = "1007", x = 0.4, y = 2, z = 0, yaw = 180, kind = "chair", profile = "seated" } } },
    -- C: a measured barstool (arrival 1.0).
    { poses = { { gid = "1002", x = 3, y = 0, z = 0, yaw = 90, kind = "barstool",
        profile = "amb_f6ac22_sit_barstool_bar", arrival = 1.0 } } },
    -- D: a bench row, three measured poses 0.45 m apart (wide).
    { flags = 2048, poses = {
        { gid = "1003", x = -3, y = 0, z = 0, yaw = 0, kind = "chair", profile = "seated" },
        { gid = "1013", x = -2.55, y = 0, z = 0, yaw = 0, kind = "chair", profile = "seated" },
        { gid = "1023", x = -2.1, y = 0, z = 0, yaw = 0, kind = "chair", profile = "seated" } } },
    -- E: an unverified chair.
    { poses = { { gid = "1004", x = 0, y = -2, z = 0, yaw = 0, kind = "chair", profile = "seatedthink",
        verification = "unverified" } } },
    -- F: a refused bed (no profile).
    { poses = { { gid = "1005", x = 5, y = 5, z = 0, yaw = 0, kind = "bed", verification = "refused" } } },
    -- G: a measured chair out of reach.
    { poses = { { gid = "1006", x = 20, y = 0, z = 0, yaw = 0, kind = "chair", profile = "seated" } } },
    -- H: a dependent pose (needs its master occupied): never offered.
    { flags = 32, poses = { { gid = "1008", x = 1.5, y = 1.5, z = 0, yaw = 0, kind = "chair", profile = "seated" } } },
    -- I: a measured wall lean.
    { poses = { { gid = "1009", x = -1, y = 2.5, z = 0, yaw = 180, kind = "lean_wall", profile = "lean" } } },
    -- J: the measured bed resource (lie, arrival 1.0, approach "player"), away from the rest.
    { poses = { { gid = "2001", x = -10, y = -10, z = 0, yaw = 90, kind = "bed", profile = "lie", arrival = 1.0 } } },
    -- K: an unverified bed 5 m from J.
    { poses = { { gid = "2002", x = -15, y = -10, z = 0, yaw = 90, kind = "bed", profile = "lie",
        verification = "unverified" } } },
}

local function world()
    local live = {}
    for _, session in pairs(core.byPlayer) do live[#live + 1] = session end
    for _, session in ipairs(live) do core:finish(session, "resource_stopping", { exit = "none" }) end
    -- Let the previous case's exit threads finish before anything is reset.
    F.teleportMode = "settle"
    F.now = F.now + 60000
    F.run()
    core.byPlayer, core.byPlayback, core.groups, core.prompts = {}, {}, {}, {}
    core.version, core.versionCheckedAt, core.pedestrians = nil, -math.huge, "unknown"
    core.trace = true
    config.verification, config.exitMode, config.buckets = { measured = true }, "approach", nil
    config.postures = M.config().postures
    F.running = { open77_furniture = true, open77_actions = true, open77_pedestrians = true }
    F.installFurniture(FURNITURE, VERSION)
    F.installActions()
    F.installPedestrians()
    F.players, F.npcs, F.animCurrent, F.actionsBusy, F.carrying = {}, {}, {}, {}, {}
    F.teleportMode, F.animRefuse = "settle", nil
    F.now = F.now + 120000
    F.reset()
    F.player(1, 0, 0, 0)
    F.player(2, 0.5, 0, 0)
end

local function claimKey(id) return "furniture:" .. VERSION .. ":" .. id end
local function holdKey(spot) return "furniture:" .. VERSION .. ":" .. spot end
local function refusedReason(pid)
    local last = F.lastClient("open77:seating:refused", pid)
    return last and last.payload.reason or nil
end
local function seated(pid) return core.byPlayer[pid] ~= nil and core.byPlayer[pid].state == "seated" end
local function released()
    return next(core.byPlayer) == nil and next(core.groups) == nil and F.claims:count() == 0 and F.guard:count() == 0
end

-- The convar default (open77_seating_postures unset, "all") offers every posture, lying included.
check(config.postures.sit == true and config.postures.lean == true and config.postures.lie == true,
    "open77_seating_postures defaults to sit, lean and lie")

-- ---------------------------------------------------------------------------
-- The happy path
-- ---------------------------------------------------------------------------
run("sit: validation, claim, NPC hold, approach, playAt with the arrival radius", function()
    world()
    F.net("open77:seating:sit", 1, "1001")
    local session = core.byPlayer[1]
    check(session ~= nil and session.state == "seated", "seated at once (the teleport settles synchronously here)")
    check(F.claims:holder(0, claimKey("1001")) ~= nil and F.claims:holder(0, claimKey("1001")).owner == "open77_seating",
        "the furniture group is claimed in bucket 0 by open77_seating")
    check(F.guard:blocks(0, 0, 2, 0) ~= nil and F.guard:blocks(0, 0.7, 2, 0) == nil, "pedestrians kept 0.6 m off the seat")
    local tp = F.teleports[1]
    check(tp and math.abs(tp.position.x) < 1e-9 and math.abs(tp.position.y - 0.8) < 1e-9 and
        math.abs(tp.position.z - 0.05) < 1e-9, "approach 1.2 m behind the chair, 5 cm up")
    check(tp and tp.options.fade == false and tp.options.heading == 0, "no fade, facing the seat's way")
    local play = F.anim("playAt")[1]
    check(play and play.profile == "seated" and play.position.y == 2 and play.yaw == 0, "playAt on the anchor")
    check(play and play.options.loop == true and play.options.arrivalRadius == 0.5, "looping, arrivalRadius 0.5")
    local state = F.lastClient("open77:seating:state", 1)
    check(state and state.payload.seated == true and state.payload.label == "Sit on the chair", "client told: seated")
    check(F.printed("[seating] SEATED player=1 furniture=1001") ~= nil, "SEATED line")
    local seen = false
    for _, entry in ipairs(F.host) do
        if entry.name == "open77_seating:seated" and entry.args[1].furnitureId == "1001" then seen = true end
    end
    check(seen, "host event open77_seating:seated")
    check(F.call("rp_bar", "current", 1).furnitureId == "1001", "current export")
    local list = F.call("rp_bar", "occupants", 0, "1001")
    check(#list == 1 and list[1] == 1, "occupants export")

    -- Stand up with the key: stop, release everything, put the body back on its approach point.
    F.players[1].position = { x = 0.3, y = 1.6, z = 0 }    -- where the exit left it
    F.net("open77:seating:stand", 1)
    check(core.byPlayer[1] == nil, "stood")
    local stop = F.anim("stopAt")[1]
    check(stop and stop.playbackId == session.playbackId, "the playback is stopped")
    check(released(), "claim and hold released")
    local after = F.lastClient("open77:seating:state", 1)
    check(after and after.payload.seated == false and after.payload.reason == "stood", "client told: stood")
    F.advance(1600)
    check(#F.teleports == 2 and F.teleports[2].position.y == 0.8, "exit: back on the approach point")
    check(F.printed("[seating] EXIT player=1 furniture=1001 mode=approach") ~= nil, "EXIT line")
end)

run("the approach is skipped when the actor already stands on it; the exit when it is already there", function()
    world()
    F.players[1].position = { x = 0.1, y = 0.8, z = 0 }
    F.net("open77:seating:sit", 1, "1001")
    check(seated(1) and #F.teleports == 0, "no teleport within 0.35 m of the approach")
    F.players[1].position = { x = 0.2, y = 0.9, z = 0 }
    F.net("open77:seating:stand", 1)
    F.advance(1600)
    check(#F.teleports == 0, "exit already on the approach point: not moved")
end)

run("the barstool plays its promoted twin with arrivalRadius 1.0 and approaches from behind", function()
    world()
    F.players[1].position = { x = 2, y = 0.5, z = 0 }
    F.net("open77:seating:sit", 1, "1002")
    local play = F.anim("playAt")[1]
    check(play and play.profile == "amb_f6ac22_sit_barstool_bar" and play.options.arrivalRadius == 1.0, "barstool")
    -- yaw 90 faces -X: behind is +X.
    local tp = F.teleports[1]
    check(tp and math.abs(tp.position.x - 4.2) < 1e-9 and math.abs(tp.position.y) < 1e-9, "approach behind the stool")
end)

run("lying is offered by default on the measured bed: prompt, intent, /sit, export", function()
    world()
    check(M.config().postures.lie == true and config.postures.lie == true, "lie is a default posture")
    F.players[1].position = { x = -10, y = -9, z = 0 }
    F.advance(300)
    local seats = F.lastClient("open77:seating:seats", 1)
    local bed = seats and seats.payload.seats[1]
    check(bed and #seats.payload.seats == 1 and bed.id == "2001", "only the measured bed is offered: "
        .. tostring(bed and bed.id))
    check(bed and bed.label == "Lie down on the bed" and bed.posture == "lie" and bed.position.z == 0.6,
        "a lie prompt: " .. tostring(bed and bed.label))
    -- The prompt's intent: lies from where the player stands (approach "player"), arrival radius 1.0.
    F.net("open77:seating:sit", 1, "2001")
    local session = core.byPlayer[1]
    check(seated(1) and session.posture == "lie" and session.kind == "bed", "lying on the bed")
    check(#F.teleports == 0 and session.approach == nil and session.approachRule == "player", "no approach move")
    local play = F.anim("playAt")[1]
    check(play and play.profile == "lie" and play.options.arrivalRadius == 1.0 and play.yaw == 90,
        "playAt lie with arrivalRadius 1.0")
    local state = F.lastClient("open77:seating:state", 1)
    check(state and state.payload.label == "Lie down on the bed" and state.payload.posture == "lie", "client told")
    check(F.claims:holder(0, claimKey("2001")) ~= nil and F.guard:count() == 1, "claimed and held like a seat")
    -- One body per bed.
    F.player(3, -10.5, -9, 0)
    F.net("open77:seating:sit", 3, "2001")
    check(refusedReason(3) == "seat_taken", "a second player is refused")
    -- Getting up: the body is put back where the player stood when asking.
    F.players[1].position = { x = -10, y = -10.2, z = 0.4 }
    F.net("open77:seating:stand", 1)
    check(released(), "released")
    F.advance(1600)
    local back = F.teleports[1]
    check(back and back.position.x == -10 and back.position.y == -9, "exit to the origin")
    -- /sit and the export reach it too.
    F.advance(1100)
    F.players[1].position = { x = -10, y = -9, z = 0 }
    F.command("sit", 1, {})
    check(seated(1) and core.byPlayer[1].furnitureId == "2001", "/sit lies on the nearest bed")
    F.call("rp_motel", "stand", 1)
    F.advance(1600)
    local seat = F.call("rp_motel", "sit", 1, "2001", { exit = "none" })
    check(seat and seat.posture == "lie" and seat.profile == "lie", "export sit")
end)

run("lying keeps the verification and posture filters", function()
    world()
    -- The unverified bed is neither prompted nor taken by default.
    F.players[1].position = { x = -15, y = -9, z = 0 }
    F.advance(300)
    local seats = F.lastClient("open77:seating:seats", 1)
    check(seats == nil or #seats.payload.seats == 0, "no prompt for an unverified bed")
    F.net("open77:seating:sit", 1, "2002")
    check(refusedReason(1) == "no_playable_pose" and core.byPlayer[1] == nil, "unverified bed refused")
    F.advance(1100)
    F.command("sit", 1, {})
    check(refusedReason(1) == "no_playable_pose" and core.byPlayer[1] == nil, "/sit does not take it either")
    config.verification = { measured = true, unverified = true }
    F.advance(3500)
    seats = F.lastClient("open77:seating:seats", 1)
    check(seats and #seats.payload.seats == 1 and seats.payload.seats[1].id == "2002", "offered once allowed")
    -- An operator who turns lying off (open77_seating_postures sit,lean).
    world()
    config.postures = { sit = true, lean = true }
    F.players[1].position = { x = -10, y = -9, z = 0 }
    F.advance(300)
    seats = F.lastClient("open77:seating:seats", 1)
    check(seats == nil or #seats.payload.seats == 0, "no lie prompt when lying is off")
    F.net("open77:seating:sit", 1, "2001")
    check(refusedReason(1) == "no_playable_pose", "lie refused when lying is off")
end)

-- ---------------------------------------------------------------------------
-- Refusals
-- ---------------------------------------------------------------------------
run("actor refusals are re-derived on the server", function()
    local cases = {
        { "player_not_alive", { alive = false } },
        { "player_not_ready", { ready = false } },
        { "player_in_vehicle", { inVehicle = true } },
        { "position_stale", { ageMs = 5000 } },
        { "position_unavailable", { position = "none" } },
        { "in_combat", { flags = { combatValid = true, aiming = true } } },
    }
    for _, case in ipairs(cases) do
        world()
        for key, value in pairs(case[2]) do
            if value == "none" then F.players[1][key] = nil else F.players[1][key] = value end
        end
        F.net("open77:seating:sit", 1, "1001")
        check(refusedReason(1) == case[1], case[1] .. ": got " .. tostring(refusedReason(1)))
        check(released() and #F.teleports == 0 and #F.anim("playAt") == 0, case[1] .. ": nothing taken or moved")
    end
    world()
    config.buckets = { [4] = true }
    F.net("open77:seating:sit", 1, "1001")
    check(refusedReason(1) == "bucket_not_enabled", "bucket_not_enabled")
    config.buckets = nil
    local _, why = core:sit(nil, "1001")
    check(why == "invalid_player", "invalid_player")
    _, why = core:sit(9, "1001")
    check(why == "player_unavailable", "player_unavailable (not connected)")
    _, why = core:sit(1, "not-an-id")
    check(why == "invalid_furniture", "invalid_furniture")
    _, why = core:sit(1, "424242")
    check(why == "unknown_furniture", "unknown_furniture")
end)

run("busy actors are refused before being moved", function()
    world()
    F.actionsBusy[1] = { opId = "op1" }
    F.net("open77:seating:sit", 1, "1001")
    check(refusedReason(1) == "actor_busy" and #F.teleports == 0, "an open77_actions operation")
    F.actionsBusy[1] = nil
    F.carrying[1] = { itemId = "i1" }
    F.net("open77:seating:sit", 1, "1001")
    check(refusedReason(1) == "actor_busy", "carrying")
    F.carrying[1] = nil
    F.animCurrent[1] = { playbackId = "emote", active = true }
    F.net("open77:seating:sit", 1, "1001")
    check(refusedReason(1) == "actor_busy" and released(), "an emote")
    F.animCurrent[1] = nil
    F.net("open77:seating:sit", 1, "1001")
    check(seated(1), "free again")
    F.advance(1100)                                     -- past the intent budget of the window
    F.net("open77:seating:sit", 1, "1007")
    check(refusedReason(1) == "already_seated", "already_seated")
end)

run("distance, verification, refused kinds and flags", function()
    world()
    F.net("open77:seating:sit", 1, "1006")
    check(refusedReason(1) == "too_far", "too_far")
    F.net("open77:seating:sit", 1, "1004")
    check(refusedReason(1) == "no_playable_pose", "unverified refused by default")
    F.net("open77:seating:sit", 1, "1005")
    check(refusedReason(1) == "no_playable_pose", "the refused bed has no profile")
    config.verification = { measured = true, unverified = true }
    F.net("open77:seating:sit", 1, "1004")
    check(seated(1) and F.anim("playAt")[1].profile == "seatedthink", "unverified allowed by configuration")
    world()
    -- Lab: any verification, an explicit profile on a refused pose, reach 4.5 m.
    F.command("seating.sit", 0, { "1", "1005", "-", "lie" })
    check(core.byPlayer[1] == nil and F.printed("refused reason=too_far") ~= nil, "lab reach is still bounded")
    F.players[1].position = { x = 4, y = 3, z = 0 }
    F.command("seating.sit", 0, { "1", "1005", "-", "lie", "1.0", "right" })
    local session = core.byPlayer[1]
    check(session and session.lab and session.profile == "lie" and session.arrivalRadius == 1.0, "lab override")
    local tp = F.teleports[1]
    check(tp and math.abs(tp.position.x - 6) < 1e-9 and math.abs(tp.position.y - 5) < 1e-9, "named approach: right")
    world()
    F.command("seating.sit", 0, { "1", "1001", "999" })
    check(F.printed("refused reason=unknown_spot") ~= nil, "unknown_spot")
end)

-- ---------------------------------------------------------------------------
-- Contention
-- ---------------------------------------------------------------------------
run("player/player: one winner, the crowded neighbour too, then the next", function()
    world()
    F.net("open77:seating:sit", 1, "1001")
    F.net("open77:seating:sit", 2, "1001")
    check(seated(1) and core.byPlayer[2] == nil and refusedReason(2) == "seat_taken", "second player refused")
    F.net("open77:seating:sit", 2, "1007")
    check(core.byPlayer[2] == nil and refusedReason(2) == "seat_taken", "a seat 0.4 m away is the same body space")
    -- While approaching, the seat is already taken.
    world()
    F.teleportMode = "defer"
    F.net("open77:seating:sit", 1, "1001")
    check(core.byPlayer[1].state == "approaching", "approaching")
    F.net("open77:seating:sit", 2, "1001")
    check(refusedReason(2) == "seat_taken", "taken while the first one approaches")
    F.settleTeleports()
    check(seated(1), "then seated")
    F.net("open77:seating:stand", 1)
    F.teleportMode = "settle"
    F.net("open77:seating:sit", 2, "1001")
    check(seated(2), "the next player wins once it is free")
end)

run("another resource's claim on the furniture group refuses the seat", function()
    world()
    local token = F.claims:acquire(0, claimKey("1002"), "res:rp_bar", 60000, "rp_bar")
    F.players[1].position = { x = 2, y = 0.5, z = 0 }
    F.net("open77:seating:sit", 1, "1002")
    check(refusedReason(1) == "target_claimed" and core.byPlayer[1] == nil, "target_claimed")
    check(F.guard:count() == 0, "no hold left behind")
    F.claims:release(token)
    -- Claims are bucket-scoped: the same furniture in bucket 5 is another claim.
    F.claims:acquire(5, claimKey("1002"), "res:rp_bar", 60000, "rp_bar")
    F.net("open77:seating:sit", 1, "1002")
    check(seated(1), "bucket 0 is free")
    F.running.open77_actions = false
    F.net("open77:seating:sit", 2, "1001")
    check(refusedReason(2) == "claims_unavailable", "no claims service, no seat")
end)

run("player/NPC: a pedestrian on the seat refuses, a seat taken keeps them off", function()
    world()
    F.npcs[1] = { npc = "77", state = "seated", source = "seated", bucket = 0, x = 3.1, y = 0, z = 0 }
    F.players[1].position = { x = 2, y = 0.5, z = 0 }
    F.net("open77:seating:sit", 1, "1002")
    check(refusedReason(1) == "npc_occupied" and core.byPlayer[1] == nil, "npc_occupied")
    check(F.claims:count() == 0 and #F.teleports == 0, "the claim is given back, nobody moved")
    F.npcs[1].bucket = 1
    F.net("open77:seating:sit", 1, "1002")
    check(seated(1), "a pedestrian in another bucket does not count")
    check(F.guard:blocks(0, 3, 0, 0) ~= nil and F.guard:blocks(1, 3, 0, 0) == nil, "held in the seat's bucket only")
    F.net("open77:seating:stand", 1)
    check(F.guard:blocks(0, 3, 0, 0) == nil, "released with the seat")
    -- Without open77_pedestrians the seat works and nothing is held.
    world()
    F.running.open77_pedestrians = false
    F.net("open77:seating:sit", 1, "1001")
    check(seated(1) and core.byPlayer[1].npc == "absent" and core.pedestrians == "absent", "no NPC coordination")
end)

run("a bench row seats two at separated poses; one claim covers them", function()
    world()
    F.players[1].position = { x = -3, y = -1, z = 0 }
    F.players[2].position = { x = -2, y = -1, z = 0 }
    F.net("open77:seating:sit", 1, "1003")
    check(seated(1) and core.byPlayer[1].spot == "1003", "first player on the nearest pose")
    F.net("open77:seating:sit", 2, "1003")
    check(seated(2) and core.byPlayer[2].spot == "1023", "second player on the alternate pose 0.9 m away")
    local group = core.byPlayer[1].group
    check(group == core.byPlayer[2].group and group.refs == 2 and F.claims:count() == 1, "one group claim, two refs")
    check(F.guard:count() == 2, "two pedestrian holds")
    F.player(3, -2.5, -1, 0)
    F.net("open77:seating:sit", 3, "1003")
    check(refusedReason(3) == "seat_taken", "the middle pose overlaps both")
    F.net("open77:seating:stand", 1)
    check(F.claims:count() == 1 and group.refs == 1, "still claimed for the second")
    F.net("open77:seating:stand", 2)
    check(released(), "released with the last")
end)

-- ---------------------------------------------------------------------------
-- Reconciliation: every end releases once; only voluntary ends move the body
-- ---------------------------------------------------------------------------
local function endCase(name, expected, trigger, exits)
    run("end: " .. name, function()
        world()
        F.net("open77:seating:sit", 1, "1001")
        local session = core.byPlayer[1]
        check(session and session.state == "seated", name .. ": seated first")
        local playback = session.playbackId
        local teleports = #F.teleports
        trigger(session)
        F.advance(2000)
        check(session.ended and session.reason == expected, name .. ": reason " .. tostring(session.reason))
        check(released(), name .. ": claim, hold and session released")
        check(core.byPlayback[playback] == nil, name .. ": playback forgotten")
        local moved = #F.teleports > teleports
        check(moved == (exits == true), name .. ": exit move " .. tostring(moved))
    end)
end

endCase("disconnect", "disconnected", function() F.players[1] = nil; F.fire("onPlayerDisconnected", "1") end)
endCase("death", "dead", function()
    F.players[1].alive = false
    F.fire("onPlayerLifeStateChanged", "1", 3, "dead")
end)
endCase("bucket change", "bucket_changed", function()
    F.players[1].bucket = 7
    F.fire("onPlayerBucketChange", "1", 0, 7)
end)
endCase("vehicle", "vehicle", function() F.fire("onPlayerEnteringVehicle", "1") end)
endCase("weapon drawn", "combat", function() F.fire("onPlayerWeaponChanged", "1", 1, "Items.Gun", true) end)
endCase("anchor never reached", "anchor_unreached", function(session)
    F.players[1].position = { x = 0, y = 1.5, z = 0.2 }
    F.fire("onPlayerAnimationChanged", "1", { playbackId = session.playbackId, active = false, reason = "anchor_unreached" })
end, true)
endCase("moved off the seat", "moved", function(session)
    F.players[1].position = { x = 3, y = 3, z = 0 }
    F.fire("onPlayerAnimationChanged", "1", { playbackId = session.playbackId, active = false, reason = "moved" })
end)
endCase("player cancelled the posture", "cancelled_by_player", function(session)
    F.players[1].position = { x = 0.3, y = 1.6, z = 0 }
    F.fire("onPlayerAnimationChanged", "1", { playbackId = session.playbackId, active = false, reason = "cancelled" })
end, true)
endCase("posture interrupted for another reason", "animation_interrupted", function(session)
    F.fire("onPlayerAnimationChanged", "1", { playbackId = session.playbackId, active = false, reason = "client_failed" })
end)
endCase("watchdog: dead without an event", "dead", function() F.players[1].alive = false end)
endCase("watchdog: gone without an event", "disconnected", function() F.players[1] = nil end)
endCase("resource stopping", "resource_stopping", function() F.fire("onResourceStop", "open77_seating") end)
endCase("stand export", "stood", function()
    F.players[1].position = { x = 0.5, y = 1.7, z = 0 }
    F.call("rp_bar", "stand", 1)
end, true)
endCase("/stand", "stood", function()
    F.players[1].position = { x = 0.5, y = 1.7, z = 0 }
    F.command("stand", 1, {})
end, true)

run("a stale animation notice changes nothing", function()
    world()
    F.net("open77:seating:sit", 1, "1001")
    F.fire("onPlayerAnimationChanged", "1", { playbackId = "pb-other", active = false, reason = "moved" })
    F.fire("onPlayerAnimationChanged", "2", { playbackId = core.byPlayer[1].playbackId, active = false, reason = "moved" })
    F.fire("onPlayerAnimationChanged", "1", { playbackId = core.byPlayer[1].playbackId, active = true })
    check(seated(1), "still seated")
    local _, why = core:stand(2)
    check(why == "not_seated", "not_seated")
    F.command("stand", 2, {})
    check(refusedReason(2) == "not_seated", "/stand while standing")
end)

run("approach failures release everything and never play", function()
    world()
    F.teleportMode = "refuse"
    F.net("open77:seating:sit", 1, "1001")
    check(core.byPlayer[1] == nil and #F.anim("playAt") == 0 and released(), "approach_failed")
    check(F.printed("reason=approach_failed") ~= nil, "approach_failed line")
    -- The body lands far from the approach (pushed by geometry): refused, and put back where it came from.
    world()
    F.teleportMode = { x = 2, y = 0.8, z = 0.05 }
    F.net("open77:seating:sit", 1, "1001")
    check(core.byPlayer[1] == nil and #F.anim("playAt") == 0 and released(), "approach_blocked")
    F.teleportMode = "settle"
    F.advance(1600)
    local back = F.teleports[#F.teleports]
    check(#F.teleports == 2 and back.position.x == 0 and back.position.y == 0, "exit to the origin")
    -- The actor dies while the body moves: the posture never starts.
    world()
    F.teleportMode = "defer"
    F.net("open77:seating:sit", 1, "1001")
    F.players[1].alive = false
    F.fire("onPlayerLifeStateChanged", "1", 2, "dead")
    F.settleTeleports()
    check(core.byPlayer[1] == nil and #F.anim("playAt") == 0 and released(), "dead during the approach")
    -- The client never settles: approach_timeout.
    world()
    F.teleportMode = "defer"
    F.net("open77:seating:sit", 1, "1001")
    F.advance(config.approachTimeoutMs + 500)
    check(core.byPlayer[1] == nil and released(), "approach_timeout")
    check(F.printed("reason=approach_timeout") ~= nil, "approach_timeout line")
    F.settleTeleports("settle_timeout")
    check(#F.anim("playAt") == 0, "a late settle starts nothing")
    -- A bucket change, or a weapon aimed, while the body moves.
    world()
    F.teleportMode = "defer"
    F.net("open77:seating:sit", 1, "1001")
    F.players[1].bucket = 3
    F.settleTeleports()
    check(core.byPlayer[1] == nil and #F.anim("playAt") == 0, "bucket_changed during the approach")
    check(refusedReason(1) == "bucket_changed", "the player is told why")
    world()
    F.teleportMode = "defer"
    F.net("open77:seating:sit", 1, "1001")
    F.players[1].flags = { combatValid = true, aiming = true }
    F.settleTeleports()
    check(core.byPlayer[1] == nil and #F.anim("playAt") == 0 and refusedReason(1) == "combat", "combat during the approach")
end)

run("playAt refusals", function()
    world()
    F.animRefuse = "animation_owned"
    F.net("open77:seating:sit", 1, "1001")
    check(core.byPlayer[1] == nil and released() and F.printed("reason=actor_busy") ~= nil, "animation_owned -> actor_busy")
    F.animRefuse = "anchor_too_far"
    F.net("open77:seating:sit", 1, "1001")
    check(core.byPlayer[1] == nil and released() and F.printed("reason=animation_refused") ~= nil, "animation_refused")
end)

-- ---------------------------------------------------------------------------
-- Dependency restarts and the catalogue version
-- ---------------------------------------------------------------------------
run("open77_actions restarts: the claim is taken again; taken by another, the seat is lost", function()
    world()
    F.net("open77:seating:sit", 1, "1001")
    F.installActions()                                -- a fresh claims service: ours is gone
    F.fire("onResourceStart", "open77_actions")
    F.advance(300)
    check(seated(1) and F.claims:holder(0, claimKey("1001")) ~= nil, "re-claimed, still seated")
    world()
    F.net("open77:seating:sit", 1, "1001")
    F.installActions()
    F.claims:acquire(0, claimKey("1001"), "res:rp_bar", 60000, "rp_bar")
    F.players[1].position = { x = 0.4, y = 1.6, z = 0 }
    F.advance(config.renewEveryMs + 300)
    check(core.byPlayer[1] == nil and F.printed("reason=claim_lost") ~= nil, "claim_lost")
    check(#F.anim("stopAt") == 1, "the posture is stopped")
    F.advance(1600)
    check(#F.teleports == 2, "and the body put back on its approach point")
end)

run("open77_pedestrians restarts: the hold comes back; a pedestrian there is reported", function()
    world()
    F.net("open77:seating:sit", 1, "1001")
    F.installPedestrians()
    check(F.guard:count() == 0, "holds gone with the restart")
    F.npcs[1] = { npc = "88", state = "seated", source = "crowd", bucket = 0, x = 0.1, y = 2, z = 0 }
    F.fire("onResourceStart", "open77_pedestrians")
    F.advance(300)
    check(F.guard:count() == 1 and seated(1), "held again (forced: the player already sits there)")
    check(F.printed("NPC_OVERLAP player=1 furniture=1001 npc=88") ~= nil, "the overlap is reported")
end)

run("a new catalogue version: same pose -> rekeyed; pose gone -> stood up", function()
    world()
    F.net("open77:seating:sit", 1, "1001")
    F.advance(config.versionCheckMs + 300)              -- the first check records the version
    F.installFurniture(FURNITURE, "furniture-1-test11111111")
    F.advance(config.versionCheckMs + 300)
    local session = core.byPlayer[1]
    check(session and session.version == "furniture-1-test11111111", "rekeyed")
    check(F.claims:holder(0, "furniture:furniture-1-test11111111:1001") ~= nil and
        F.claims:holder(0, claimKey("1001")) == nil, "claim moved to the new key")
    check(F.guard:count() == 1, "one hold")
    local moved = {}
    for i, item in ipairs(FURNITURE) do moved[i] = item end
    moved[1] = { poses = { { gid = "1001", x = 0, y = 2.5, z = 0, yaw = 0, kind = "chair", profile = "seated" } } }
    F.installFurniture(moved, "furniture-1-test22222222")
    F.advance(config.versionCheckMs + 300)
    check(core.byPlayer[1] == nil and F.printed("reason=furniture_changed") ~= nil, "furniture_changed")
    check(released(), "released")
end)

-- ---------------------------------------------------------------------------
-- Prompts and /sit
-- ---------------------------------------------------------------------------
run("prompts: the nearest few playable, free seats; never every row around", function()
    world()
    F.advance(300)
    local seats = F.lastClient("open77:seating:seats", 1)
    local ids = {}
    for i, seat in ipairs(seats and seats.payload.seats or {}) do ids[i] = seat.id end
    check(table.concat(ids, ",") == "1001,1007,1009", "nearest three: " .. table.concat(ids, ","))
    local lean = seats.payload.seats[3]
    check(lean.label == "Lean on the wall" and lean.position.z == 1.0, "a lean prompt at chest height")
    check(seats.payload.seats[1].label == "Sit on the chair" and seats.payload.seats[1].position.z == 0.6, "sit prompt")
    -- No re-query while standing still; a seat taken by player 2 drops out once player 1 moves.
    local count = #F.clientEvents("open77:seating:seats", 1)
    F.advance(1000)
    check(#F.clientEvents("open77:seating:seats", 1) == count, "nothing sent while unchanged")
    F.players[2].position = { x = 0.2, y = 1, z = 0 }
    F.net("open77:seating:sit", 2, "1001")
    check(seated(2), "player 2 seated: " .. tostring(refusedReason(2)))
    F.players[1].position = { x = 0, y = 0.9, z = 0 }
    F.advance(500)
    seats = F.lastClient("open77:seating:seats", 1)
    ids = {}
    for i, seat in ipairs(seats.payload.seats) do ids[i] = seat.id end
    check(table.concat(ids, ",") == "1009", "the taken seat and its crowded neighbour leave: " ..
        table.concat(ids, ","))
    local mine = F.lastClient("open77:seating:seats", 2)
    check(mine and #mine.payload.seats == 0, "a seated player is offered nothing")
    -- A pedestrian on the lean spot removes it too.
    F.npcs[1] = { npc = "90", state = "seated", bucket = 0, x = -1, y = 2.5, z = 0 }
    F.players[1].position = { x = 0, y = 0, z = 0 }
    F.advance(500)
    seats = F.lastClient("open77:seating:seats", 1)
    ids = {}
    for i, seat in ipairs(seats.payload.seats) do ids[i] = seat.id end
    check(table.concat(ids, ",") == "1002,1003", "NPC-held seat not offered: " .. table.concat(ids, ","))
    -- A dead player is offered nothing.
    F.players[1].alive = false
    F.advance(3500)
    seats = F.lastClient("open77:seating:seats", 1)
    check(#seats.payload.seats == 0, "nothing for the dead")
end)

run("/sit takes the nearest free seat; refusals reach the player", function()
    world()
    F.command("sit", 1, {})
    check(seated(1) and core.byPlayer[1].furnitureId == "1001", "nearest")
    F.command("sit", 2, {})
    check(seated(2) and core.byPlayer[2].furnitureId == "1002", "the next free one (1007 overlaps 1001): " ..
        tostring(core.byPlayer[2] and core.byPlayer[2].furnitureId))
    F.player(3, 20, 5, 0)
    F.command("sit", 3, {})
    check(refusedReason(3) == "no_playable_pose", "nothing in reach")
    F.command("sit", 0, {})
    check(F.printed("/sit is a player command") ~= nil, "console told to use seating.sit")
    F.running.open77_furniture = false
    F.player(4, 0, -1, 0)
    F.command("sit", 4, {})
    check(refusedReason(4) == "furniture_unavailable", "furniture_unavailable")
    F.running.open77_furniture = true
    F.exportHandlers.open77_furniture.nearby = function() return nil, "indexing" end
    F.command("sit", 4, {})
    check(refusedReason(4) == "indexing", "indexing")
end)

run("exports sit / sitNearest from another resource", function()
    world()
    local seat = F.call("rp_bar", "sit", 1, "1001", { exit = "none", approach = "player" })
    check(seat and seat.furnitureId == "1001" and seat.state == "seated" and #F.teleports == 0, "approach=player")
    F.call("rp_bar", "stand", 1)
    F.advance(1600)
    check(#F.teleports == 0, "exit none")
    local again, why = F.call("rp_bar", "sit", 2, "1001", { spot = "1001" })
    check(again and again.spot == "1001", "explicit spot " .. tostring(why))
    local nearest = F.call("rp_bar", "sitNearest", 1)
    check(nearest and nearest.furnitureId == "1009", "sitNearest")
    local _, busy = F.call("rp_bar", "sit", 1, "1002")
    check(busy == "already_seated", "already_seated through the export")
end)

run("client intents are rate limited", function()
    world()
    F.running.open77_furniture = false
    for _ = 1, 10 do F.net("open77:seating:sit", 1, "1001") end
    check(#F.clientEvents("open77:seating:refused", 1) == config.intentBudget, "only the budget is answered")
    F.net("open77:seating:sit", 1, { "not", "an", "id" })
end)

-- ---------------------------------------------------------------------------
-- Lab console
-- ---------------------------------------------------------------------------
run("lab console: near, claims, status, exit, verification, trace", function()
    world()
    F.npcs[1] = { npc = "77", state = "seated", bucket = 0, x = 3, y = 0, z = 0 }
    F.claims:acquire(0, claimKey("1009"), "res:rp_bar", 60000, "rp_bar")
    F.net("open77:seating:sit", 2, "1001")
    F.command("seating.near", 0, { "1", "8", "4" })
    check(F.printed("[seating] NEAR player=1 bucket=0") ~= nil, "NEAR header")
    check(F.printed("id=1001 kind=chair") and F.printed("id=1001 kind=chair"):find("status=player:2", 1, true),
        "a seat a player holds")
    check(F.printed("id=1002 kind=barstool") and F.printed("id=1002 kind=barstool"):find("status=npc:77:seated", 1, true),
        "a seat an NPC holds")
    check(F.printed("id=1009 kind=lean_wall") and F.printed("id=1009 kind=lean_wall"):find("status=claimed:rp_bar", 1, true),
        "a seat another resource claimed")
    check(F.printed("id=1004 kind=chair") and F.printed("id=1004 kind=chair"):find("verification=unverified", 1, true),
        "unverified seats are listed in the lab")
    check(F.printed("arrivalRadius=1.00") ~= nil, "arrival radius printed")
    F.command("seating.claims", 0, {})
    check(F.printed("[seating] SESSION player=2 furniture=1001") ~= nil, "SESSION line")
    check(F.printed("[seating] CLAIM bucket=0 key=" .. claimKey("1001")) ~= nil, "CLAIM line")
    F.command("seating.status", 0, {})
    check(F.printed("[seating] STATUS version=" .. VERSION) ~= nil, "STATUS line")
    F.command("seating.exit", 0, { "check" })
    check(config.exitMode == "check", "exit mode")
    F.command("seating.verification", 0, { "all" })
    check(config.verification.unverified == true, "verification all")
    F.command("seating.trace", 0, { "off" })
    check(core.trace == false, "trace off")
    F.command("seating.stand", 0, { "2", "none" })
    check(core.byPlayer[2] == nil and F.printed("[seating] STAND player=2 -> ok") ~= nil, "lab stand")
    F.command("seating.sit", 0, {})
    check(F.printed("usage: seating.sit") ~= nil, "usage")
    -- Lab commands are restricted; the player ones are not.
    check(F.commands["seating.sit"].restricted == true and F.commands["seating.near"].restricted == true, "restricted")
    check(F.commands["sit"].restricted == false and F.commands["stand"].restricted == false, "players' commands")
end)

run("a seated player moved far away (server teleport) is never pulled back by the exit", function()
    for _, mode in ipairs({ "approach", "check" }) do
        world()
        config.exitMode = mode
        F.net("open77:seating:sit", 1, "1001")
        check(seated(1), mode .. ": seated")
        local before = #F.teleports
        F.players[1].position = { x = 4.5, y = 6.0, z = 0 }   -- a Warden teleport, 7 m away
        F.net("open77:seating:stand", 1)                      -- the interrupted pose reads as a cancel
        F.advance(1600)
        check(#F.teleports == before, mode .. ": not moved back to the seat")
        check(F.printed("move=false") ~= nil, mode .. ": EXIT says move=false")
    end
end)

run("the check exit mode moves only an unsafe exit", function()
    world()
    config.exitMode = "check"
    F.net("open77:seating:sit", 1, "1001")
    F.players[1].position = { x = 0.4, y = 1.4, z = 0 }   -- beside the chair: fine
    F.net("open77:seating:stand", 1)
    F.advance(1600)
    check(#F.teleports == 1, "a normal exit is left alone")
    F.net("open77:seating:sit", 1, "1001")
    F.players[1].position = { x = 0.4, y = 1.4, z = -3 }  -- fell through the floor
    F.net("open77:seating:stand", 1)
    F.advance(1600)
    check(#F.teleports == 3 and F.teleports[3].position.y == 0.8, "a fall is put back on the approach point")
end)

run("nothing is held for a stale player and the sweep never raised", function()
    world()
    F.net("open77:seating:sit", 1, "1001")
    F.net("open77:seating:sit", 2, "1009")
    F.fire("onPlayerDisconnected", "1")
    F.players[1] = nil
    F.fire("onPlayerDisconnected", "2")
    F.players[2] = nil
    F.advance(1000)
    check(released(), "both released")
    check(F.printed("sweep raised") == nil and F.printed("prompt pass raised") == nil, "no sweep error")
end)

run("one prompt pass for 32 players stays far inside the instruction quota", function()
    world()
    local list = {}
    for i = 1, 32 do
        F.player(10 + i, (i % 8) * 0.5 - 2, (i // 8) * 0.5 - 1, 0)
        list[#list + 1] = 10 + i
    end
    local counted = 0
    debug.sethook(function() counted = counted + 1000 end, "", 1000)
    core:refreshPrompts(list)
    core:refreshPrompts(list)
    debug.sethook()
    -- The callees (the furniture index, the seat guard) run here in-process; on the
    -- server each export call has its own counter, so this over-counts.
    check(counted < 1000000, "two passes cost " .. counted .. " instructions")
    PROMPT_PASS_INSTRUCTIONS = counted
end)

TestResult = { passed = passed, failed = #failures, failures = failures,
    promptPassInstructions = PROMPT_PASS_INSTRUCTIONS }
