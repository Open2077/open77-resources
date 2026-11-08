-- =============================================================================
-- open77_scenes -- tests/scenes_test.lua
-- =============================================================================
-- The real server half against tests/fakes.lua: geometry, the scene lifecycle
-- (start -> seated -> get up -> completed), a get-up asked during the entry,
-- pose changes, every refusal, a scene replaced or lost, prompts, resource
-- spots and the lab console. Nothing here runs a game: these prove the
-- bookkeeping and the calls made to the RP animation service, not the bodies.
-- =============================================================================

local F = Open77ScenesFakes
local S = Open77Scenes
local runtime = Open77ScenesRuntime
assert(F and S and runtime, "fakes, shared/scenes.lua and server/main.lua must load first")
local core = runtime.core

local passed, failures = 0, {}
local function check(cond, msg)
    if cond then passed = passed + 1 else failures[#failures + 1] = msg or "assertion failed" end
end
local function near(a, b, msg) check(math.abs(a - b) < 1e-3, (msg or "near") .. ": " .. tostring(a) .. " ~= " .. tostring(b)) end
local function sameYaw(a, b, msg) near(S.wrap(a - b), 0, msg) end
local function run(name, fn)
    local ok, err = pcall(fn)
    if not ok then failures[#failures + 1] = name .. ": runtime error: " .. tostring(err) end
end
local function reset()
    for pid in pairs(core.byPlayer) do core.byPlayer[pid] = nil end
    core.taken, core.prompts = {}, {}
    F.reset()
    F.players = {}
end

local SCENE = S.definitions.ripperdoc
-- The test kind (tests/fakes.lua): anchor 0.5 m along the chair's +Y, turned 180 degrees.
-- The stand point of the ripperdoc scene in the anchor frame is (-0.057, 1.584).

run("the shipped scene and the generated spots load", function()
    check(SCENE ~= nil and SCENE.profile == "ripperdoc", "ripperdoc scene defined")
    check(SCENE.enter.durationMs == 6800 and SCENE.exit.durationMs == 3867, "measured clip lengths")
    check(#SCENE.idles == 2, "two seated loops")
    check(core.spots["chair@0_0_0"] ~= nil and core.spots["unknown@1_1_1"] == nil, "a spot of an unclaimed kind is skipped")
    for _, kind in ipairs({ "surgical_chair_a", "surgical_chair_a_mirrored", "surgical_chair_b" }) do
        check(S.furniture[kind] and S.furniture[kind].scene == "ripperdoc", kind .. " plays the ripperdoc scene")
    end
end)

run("geometry: compose and anchor", function()
    local p = S.compose({ x = 10, y = 0, z = 1, yaw = 90 }, { x = 1, y = 0, z = 0.5, yaw = 10 })
    near(p.x, 10, "x"); near(p.y, 1, "y"); near(p.z, 1.5, "z"); near(p.yaw, 100, "yaw")
    near(S.wrap(190), -170, "wrap")
    local anchor = S.anchorOf({ kind = "test_chair", x = 0, y = 0, z = 0, yaw = 0 })
    near(anchor.x, 0, "anchor x"); near(anchor.y, 0.5, "anchor y"); sameYaw(anchor.yaw, 180, "anchor yaw")
    local ok = pcall(S.define, "Bad Id", {})
    check(not ok, "a malformed scene id is refused")
    ok = pcall(S.define, "noidle", { profile = "x", idles = {} })
    check(not ok, "a scene needs an idle")
    ok = pcall(S.define, "short", { profile = "x", idles = { { clip = "a" } }, enter = { clip = "b", durationMs = 10 } })
    check(not ok, "a timed clip needs its measured length")
end)

run("start: sit down then stay seated, on one anchor", function()
    reset()
    F.player(7, 0.1, -1.0, 0)
    local state, why = core:start(7, "chair@0_0_0")
    check(state ~= nil, "start accepted: " .. tostring(why))
    local call = F.calls[1]
    check(call and #call.steps == 2, "two steps")
    check(call.steps[1].clip == "cyberm__ripperdoc__enter" and call.steps[1].durationMs == 6800, "entry first, measured")
    check(call.steps[2].clip == "cyberm__ripperdoc__idle" and call.steps[2].durationMs == nil, "idle held")
    check(call.options.hold == true and call.options.arrivalRadius == 1.5, "hold + arrival radius")
    near(call.position.y, 0.5, "anchor y"); sameYaw(call.yaw, 180, "anchor yaw")
    -- stand = anchor (0, 0.5, yaw 180) composed with (-0.057, 1.584, yaw 2.13)
    near(call.options.standAt.x, 0.057, "stand x"); near(call.options.standAt.y, 0.5 - 1.584, "stand y")
    -- The waiting body faces the chair (anchor yaw 180 + wait yaw -177.94).
    sameYaw(call.options.standAt.yaw, 2.06, "wait yaw")
    check(core:holder(0, "chair@0_0_0") == 7, "spot taken")
    local sent = F.lastSent("open77:scenes:state", 7)
    check(sent and sent.active == true and sent.phase == "entering" and #sent.idles == 2, "client told the scene runs")
    check(F.events[#F.events].name == "open77_scenes:started", "started event")
    -- The service reaches the held step: seated.
    core:onAnimation(7, { playbackId = state.playbackId, active = true, step = 1 })
    check(core.byPlayer[7].phase == "idle", "seated after the entry")
end)

run("change pose reuses the anchor; get up plays the exit then completes", function()
    local session = core.byPlayer[7]
    local before = #F.calls
    local idle, why = core:setIdle(7)
    check(idle ~= nil and idle.idle == 2, "next idle: " .. tostring(why))
    local call = F.calls[before + 1]
    check(call.steps[1].clip == "cyberm__ripperdoc__idle_device" and call.options.hold == true, "second idle held")
    near(call.position.y, 0.5, "same anchor")
    check(core:setIdle(7, 9) == nil, "an unknown idle is refused")
    F.headings = {}
    check(core:stand(7) == true, "stand accepted")
    check(#F.headings == 0, "the body does not turn while the camera shows the get-up")
    F.now = F.now + 3867
    core:tick()
    check(#F.headings == 0, "by default the body waits for the get-up to complete")
    call = F.calls[#F.calls]
    check(#call.steps == 1 and call.steps[1].clip == "cyberm__ripperdoc__exit" and call.steps[1].durationMs == 3867, "exit step")
    check(call.options.hold == false, "the exit completes on its own")
    check(session.phase == "exiting", "exiting")
    check(core:stand(7) == true and #F.calls == before + 2, "a second stand is idempotent")
    check(core:setIdle(7) == nil, "no pose change while getting up")
    core:onAnimation(7, { playbackId = session.playbackId, active = false, reason = "completed" })
    check(#F.headings == 1 and math.abs(S.wrap(F.headings[1].yaw - (180 + 2.13))) < 1e-3,
        "the body turns to where the get-up ends once it completed")
    check(core.byPlayer[7] == nil and core:holder(0, "chair@0_0_0") == nil, "spot freed")
    local sent = F.lastSent("open77:scenes:state", 7)
    check(sent and sent.active == false and sent.reason == "stood", "client told the scene ended")
end)

run("a get-up asked during the entry waits for the seat", function()
    reset()
    F.player(7, 0, -1, 0)
    local state = core:start(7, "chair@0_0_0")
    check(core:stand(7) == true and #F.calls == 1, "queued, nothing played yet")
    core:onAnimation(7, { playbackId = state.playbackId, active = true, step = 1 })
    local call = F.calls[2]
    check(call and call.steps[1].clip == "cyberm__ripperdoc__exit", "exit played once seated")
end)

run("refusals", function()
    reset()
    F.player(7, 0, -1, 0)
    F.player(8, 0.2, -1, 0)
    F.player(9, 50, 50, 0)
    check(select(2, core:start(7, "nope")) == "unknown_spot", "unknown spot")
    check(select(2, core:start(9, "chair@0_0_0")) == "too_far", "too far")
    F.player(10, 0, -1, 2.5)
    check(select(2, core:start(10, "chair@0_0_0")) == "too_far", "a floor above is too far")
    F.player(11, 0, -1, 0, { inVehicle = true })
    check(select(2, core:start(11, "chair@0_0_0")) == "player_in_vehicle", "vehicle")
    F.player(12, 0, -1, 0, { alive = false })
    check(select(2, core:start(12, "chair@0_0_0")) == "player_not_alive", "dead")
    check(core:start(7, "chair@0_0_0") ~= nil, "first player sits")
    check(select(2, core:start(8, "chair@0_0_0")) == "spot_taken", "taken")
    check(select(2, core:start(7, "chair@0_0_0")) == "already_in_scene", "already")
    F.current[8] = { playbackId = "other", active = true }
    F.player(8, 4.5, 0.1, 0)
    check(select(2, core:start(8, "chair@4_0_0")) == "actor_busy", "busy in another animation")
    F.current[8] = nil
    F.refuseNext = "anchor_move_refused"
    check(select(2, core:start(8, "chair@4_0_0")) == "anchor_move_refused", "service refusal surfaces")
    check(core:holder(0, "chair@4_0_0") == nil, "a refused start holds nothing")
    check(select(2, core:stand(8)) == "not_in_scene", "stand without a scene")
    check(select(2, core:setIdle(7)) == "scene_busy", "pose change during the entry")
end)

run("a scene replaced, stopped, lost or disconnected frees its spot", function()
    reset()
    F.player(7, 0, -1, 0)
    local state = core:start(7, "chair@0_0_0")
    core:onAnimation(7, { playbackId = "someone-else", active = true })
    check(core.byPlayer[7] == nil, "replaced by another resource")
    check(F.lastSent("open77:scenes:state", 7).reason == "replaced", "reason replaced")
    F.current[7] = nil -- the other resource's action ended
    state = core:start(7, "chair@0_0_0")
    core:onAnimation(7, { playbackId = state.playbackId, active = false, reason = "moved" })
    check(core.byPlayer[7] == nil and F.lastSent("open77:scenes:state", 7).reason == "moved", "moved")
    F.current[7] = nil
    state = core:start(7, "chair@0_0_0")
    F.current[7] = nil
    F.now = F.now + 5000
    core:tick()
    check(core.byPlayer[7] == nil and F.lastSent("open77:scenes:state", 7).reason == "lost", "lost when the service forgot it")
    state = core:start(7, "chair@0_0_0")
    F.fire("onPlayerDisconnected", 7)
    check(core.byPlayer[7] == nil and F.stops[#F.stops] == state.playbackId, "disconnect stops the playback")
    state = core:start(7, "chair@0_0_0")
    check(core:stand(7, { instant = true }) == true and core.byPlayer[7] == nil, "instant stand")
end)

run("prompts list the free spots in reach, nearest first", function()
    reset()
    F.player(7, 0, -1, 0)
    F.player(8, 3.5, 0, 0)
    core:refreshPrompts({ 7, 8 })
    local seven = F.lastSent("open77:scenes:spots", 7)
    check(seven and #seven.spots == 1 and seven.spots[1].id == "chair@0_0_0", "one spot for 7")
    check(seven.spots[1].label == "Lie down", "prompt label from the scene")
    near(seven.spots[1].position.z, 0.9, "card lifted")
    local count = #F.sent
    core:refreshPrompts({ 7, 8 })
    check(#F.sent == count, "unchanged prompts are not resent")
    core:start(7, "chair@0_0_0")
    core:refreshPrompts({ 7, 8 })
    check(#F.lastSent("open77:scenes:spots", 7).spots == 0, "no prompts while in a scene")
    local eight = F.lastSent("open77:scenes:spots", 8)
    for _, spot in ipairs(eight.spots) do check(spot.id ~= "chair@0_0_0", "a taken spot is not offered") end
end)

run("resources register spots of their own, and take them with them", function()
    reset()
    F.invoker = "lightrp_clinic"
    local spot, why = F.exports.registerSpot({ id = "clinic:1", scene = "ripperdoc", x = 20, y = 0, z = 0, yaw = 45 })
    check(spot ~= nil, "registered: " .. tostring(why))
    check(select(2, F.exports.registerSpot({ id = "clinic:2", scene = "nope", x = 0, y = 0, z = 0 })) == "unknown_scene", "unknown scene")
    check(select(2, F.exports.registerSpot({ id = 5 })) == "invalid_spot", "invalid spot")
    F.invoker = "another"
    check(select(2, F.exports.removeSpot("clinic:1")) == "spot_owned", "only the owner removes it")
    F.player(7, 20, -1.5, 0)
    local state = F.exports.start(7, "clinic:1")
    check(state ~= nil and state.anchor.yaw == 45, "a registered anchor is used as is")
    F.fire("onResourceStop", "lightrp_clinic")
    check(core.spots["clinic:1"] == nil, "spots leave with their resource")
    F.invoker = nil
end)

run("client intents and the lab console", function()
    reset()
    F.player(7, 0, -1, 0)
    F.net("open77:scenes:start", 7, "chair@0_0_0")
    check(core.byPlayer[7] ~= nil, "net start")
    F.net("open77:scenes:start", 7, "chair@0_0_0")
    check(F.lastSent("open77:scenes:refused", 7).reason == "already_in_scene", "refusal reaches the client")
    F.net("open77:scenes:sync", 7)
    check(F.lastSent("open77:scenes:state", 7).active == true, "sync answers the current scene")
    check(F.commands["scenes.tune"].restricted == true and F.commands["scene"].restricted == false, "console restricted, /scene not")
    F.commands["scenes.tune"].fn(0, { "test_chair", "0.1", "0.2", "0.3", "90" })
    local anchor = S.anchorOf({ kind = "test_chair", x = 0, y = 0, z = 0, yaw = 0 })
    near(anchor.x, 0.1, "tuned x"); near(anchor.z, 0.3, "tuned z"); near(anchor.yaw, 90, "tuned yaw")
    F.commands["scenes.tune"].fn(0, { "test_chair", "0", "0.5", "0", "180" })
    for _ = 1, 10 do F.net("open77:scenes:idle", 7) end
    check(F.lastSent("open77:scenes:refused", 7) ~= nil, "intents are rate limited or refused, never raised")
end)

TestResult = { passed = passed, failed = #failures, failures = failures }
