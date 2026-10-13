-- =============================================================================
-- open77_actions -- tests/carry_test.lua  (row A5)
-- =============================================================================
-- The carry helper on the real server half: pickup with a grip marker, the
-- carry session and its control claims, putdown with commit at the release
-- marker, custody changing only through the owner's commit hook, every drop
-- path, refused putdowns resuming the carry, vehicle slots, projection
-- retries, first-person fallback and stale notices.
--
-- Load order: tests/fakes.lua, shared/model.lua, server/claims.lua,
-- server/engine.lua, server/carry.lua, server/main.lua, this file.
-- =============================================================================

local F = Open77ActionsFakes
local R = Open77ActionsRuntime
assert(F ~= nil and R ~= nil, "fakes and server/main.lua must load first")
local E, C = R.engine, R.carry
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

local calls, behaviour
local function resetHooks()
    calls = { pickup = {}, putdown = {}, dropped = {}, cancel = {} }
    behaviour = {
        pickup = function(ctx) return { custody = "unchanged" } end,
        putdown = function(ctx) return { moved = ctx.carry.itemId } end,
    }
end
resetHooks()
F.exportHandlers[JOB] = {
    pk = function(ctx) calls.pickup[#calls.pickup + 1] = ctx; return behaviour.pickup(ctx) end,
    pd = function(ctx) calls.putdown[#calls.putdown + 1] = ctx; return behaviour.putdown(ctx) end,
    dr = function(ctx) calls.dropped[#calls.dropped + 1] = ctx; return true end,
    x = function(ctx) calls.cancel[#calls.cancel + 1] = ctx; return true end,
}

local function kind(overrides)
    local def = { id = "crate", model = "crate.small", label = "crate",
        hooks = { pickup = "pk", putdown = "pd", dropped = "dr", cancel = "x" } }
    for k, v in pairs(overrides or {}) do def[k] = v end
    local key, why = F.call(JOB, "carryDefine", def)
    assert(key, "carryDefine failed: " .. tostring(why))
    return key
end

local function place(position, data)
    local id, why = F.call(JOB, "carryPlace", "crate", { position = position or { x = 1, y = 0, z = 0 },
        yaw = 90, bucket = 0, data = data or { container = "world:abc" } })
    assert(id, "carryPlace failed: " .. tostring(why))
    return id
end

local function world()
    for pid in pairs(C.sessions) do C:drop(pid, "cancelled") end
    for _, op in pairs(E.ops) do
        if not M.TERMINAL[op.state] or op.trailing then E:cancel(op, "cancelled", "cancel") end
    end
    for _, item in pairs(C.items) do C:removeItem(item, "removed") end
    F.run()
    E.ops, E.opOrder, E.active, E.byPlayback, E.cooldowns, E.epochs = {}, {}, {}, {}, {}, {}
    C.sessions, C.byPlayback, C.projections, C.items, C.itemCounts, C.kinds = {}, {}, {}, {}, {}, {}
    E:undefine(JOB); E:removeTargets(JOB)
    E.claims = Open77ActionsClaims.new({ now = E.P.now })
    F.generations[JOB] = 3
    E.owners[JOB] = nil
    F.players, F.anim, F.vehicles, F.props = {}, {}, {}, {}
    F.attachRefuse, F.animRefuse = nil, nil
    F.deferred = {}
    for _, line in ipairs(F.logs) do
        if line:find("sweep raised", 1, true) then F.threadErrors[#F.threadErrors + 1] = line end
    end
    F.reset()
    resetHooks()
    F.now = F.now + 10000
    F.player(1, 0, 0, 0)
    F.player(2, 0, 5, 0)
    kind()
end

local K = C.kinds
local function pickupMs() return C.kinds["job:crate"].pickupMs end
local function gripMs() return C.kinds["job:crate"].gripMs end
local function putdownMs() return C.kinds["job:crate"].putdownMs end
local function releaseMs() return C.kinds["job:crate"].releaseMs end

local function pickUp(pid, itemId)
    F.net("open77:actions:intent", pid, "open77_actions:carry_pickup", "item:" .. itemId)
    local op = E.active[pid]
    F.advance(pickupMs() + 200)
    return op
end

local function session(pid) return C.sessions[pid] end

-- ---------------------------------------------------------------------------
run("kind definition: measured durations, separate grip and release markers", function()
    world()
    local k = C.kinds["job:crate"]
    check(k.pickupMs == 1333 and k.putdownMs == 2333, "durations from clipDurationsMs")
    check(k.gripMs > 0 and k.gripMs < k.pickupMs, "grip marker inside the pickup clip")
    check(k.releaseMs > 0 and k.releaseMs < k.putdownMs, "release marker inside the putdown clip")
    local key = F.call(JOB, "carryDefine", { id = "custom", model = "crate.cardboard", gripMs = 300, releaseMs = 900,
        binding = { bone = "RightHand", offset = { 0, 0, 0 }, firstPerson = "hide" } })
    check(C.kinds[key].gripMs == 300 and C.kinds[key].releaseMs == 900, "markers configurable apart from duration")
    check(C.kinds[key].binding.firstPerson == "hide", "first-person placement configurable")
    local _, why = F.call(JOB, "carryDefine", { id = "nomodel" })
    check(why == "invalid_definition", "a kind needs a model")
end)

run("place: owned prop plus a pickup prompt in the bucket", function()
    world()
    local id = place()
    check((E.ownerCounts[JOB] or { targets = 0 }).targets == 0, "item prompts do not use the owner's target budget")
    C:hideTarget(C.items[id]); C:showTarget(C.items[id])
    check((E.ownerCounts[JOB] or { targets = 0 }).targets == 0, "hiding and showing keeps the budget intact")
    local item = C.items[id]
    check(item and F.props[item.propId] and F.props[item.propId].model == "crate.small", "prop created")
    local push = F.lastClient("open77:actions:targets", 1)
    check(push and push.payload.upsert[1].key == "item:" .. id, "pickup prompt pushed")
    check(push.payload.upsert[1].choices[1].action == "open77_actions:carry_pickup", "prompt offers the pickup")
    check(push.payload.upsert[1].requires == "empty", "prompt only for empty hands")
    check(math.abs(push.payload.upsert[1].promptHeight - 0.7) < 1e-9, "the card sits just above the item, not at eye level")
    check(push.payload.upsert[1].position.z == item.position.z, "the target stands on the item's base, where the server measures")
end)

run("place: a kind moves its pickup card", function()
    world()
    kind({ promptHeight = 0.6 })
    local id = place()
    local push = F.lastClient("open77:actions:targets", 1)
    check(push and push.payload.upsert[1].key == "item:" .. id and math.abs(push.payload.upsert[1].promptHeight - 1.1) < 1e-9,
        "the kind's promptHeight reaches the prompt")
    local bad = F.call(JOB, "carryDefine", { id = "tall", model = "crate.small", promptHeight = 9 })
    check(bad == nil, "a card above 2 m is refused")
    kind()
end)

run("pickup: grip marker attaches, commit starts the session, the pose continues", function()
    world()
    local id = place()
    F.net("open77:actions:intent", 1, "open77_actions:carry_pickup", "item:" .. id)
    local op = E.active[1]
    check(op ~= nil and op.state == "presenting", "pickup presenting")
    check(F.anim[1] and F.anim[1].kind == "sequence" and F.anim[1].profile == "carry_pickup>carry",
        "one sequence: carry_pickup then the carry hold")
    check(C.items[id].state == "lifting", "item lifting")
    local removal = F.lastClient("open77:actions:targets", 1)
    check(removal and removal.payload.remove[1] == "item:" .. id, "prompt withdrawn while lifted")
    local prop = F.props[C.items[id].propId]
    F.advance(gripMs() - 200)
    check(prop.attachment == nil, "not attached before the grip marker")
    F.advance(300)
    check(prop.attachment and prop.attachment.bone == "Chest" and prop.attachment.parentId == 1, "attached at grip")
    check(type(prop.attachment.firstPerson) == "table", "with the first-person placement")
    check(#calls.pickup == 0, "no commit at grip: grip is presentation")
    F.advance(pickupMs() - gripMs() + 200)
    check(#calls.pickup == 1 and calls.pickup[1].carry.itemId == id, "pickup commit hook with the item")
    check(calls.pickup[1].carry.data.container == "world:abc", "the author's container id reaches the hook")
    check(E.ops[op.opId].state == "committed", "pickup committed")
    local s = session(1)
    check(s ~= nil and s.itemId == id and C.items[id].state == "carried", "carry session started")
    check(F.anim[1] and F.anim[1].playbackId == op.playbackId, "the hold keeps playing (not stopped at commit)")
    check(E.claims:count() == 1, "the item stays claimed while carried")
    local carryMsg = F.lastClient("open77:actions:carry", 1)
    check(carryMsg and carryMsg.payload.itemId == id and carryMsg.payload.claims.walkSpeed == 1.2 and
        carryMsg.payload.claims.jump == true and carryMsg.payload.claims.attack == true and
        carryMsg.payload.claims.sprint == true,
        "client told: walk mode, no jump, no attack, no sprint")
    local pub = F.call(JOB, "carrying", 1)
    check(pub and pub.itemId == id and pub.carrier == 1, "carrying() export")
    F.players[1].position = { x = 30, y = 0, z = 0 }
    F.advance(500)
    check(session(1) ~= nil, "walking with the item does not end the carry")
end)

run("putdown on the ground: commit at the release marker, projection follows", function()
    world()
    local id = place()
    pickUp(1, id)
    F.players[1].position = { x = 10, y = 0, z = 0 }
    F.players[1].heading = 0
    F.advance(200)
    F.net("open77:actions:putdown", 1)
    local op = E.active[1]
    check(op and op.kind == "carry_putdown" and F.anim[1].profile == "carry_putdown", "putdown clip plays")
    F.advance(releaseMs() - 200)
    check(#calls.putdown == 0 and C.items[id].state == "carried", "nothing moves before the release marker")
    F.advance(300)
    check(#calls.putdown == 1 and calls.putdown[1].carry.destination.kind == "ground", "putdown commit at release")
    local item = C.items[id]
    local prop = F.props[item.propId]
    check(item.state == "ground" and prop.attachment == nil, "projected to the ground after commit")
    check(math.abs(prop.position.x - 10) < 0.01 and prop.position.y > 0.5, "in front of the carrier")
    check(session(1) == nil and E.claims:count() == 0, "session ended, claim released")
    local clear = F.lastClient("open77:actions:carry", 1)
    check(clear and clear.payload.itemId == false, "client claims released")
    check(E.targets["item:" .. id] ~= nil, "pickup prompt back on the ground")
    check(E.active[1] ~= nil and E.active[1].trailing, "putdown clip finishes after the commit")
    F.advance(putdownMs())
    check(E.active[1] == nil, "presentation over")
    local events = table.concat(F.carryEvents(id), ",")
    check(events == "placed,gripped,picked_up,put_down", "carry events: " .. events)
end)

run("putdown into a vehicle slot with a destination claim", function()
    world()
    F.vehicles[10] = { position = { x = 2, y = 0, z = 0 }, bucket = 0 }
    local a, b = place(), place({ x = 0, y = 4, z = 0 })
    pickUp(1, a)
    pickUp(2, b)
    local op = F.call(JOB, "carryPutdown", 1, { kind = "vehicle", vehicleId = 10, offset = { x = 0, y = -1.5, z = 1 },
        claimKey = "veh:10:slot1" })
    check(op ~= nil and op.state == "presenting", "putdown into the truck started")
    F.players[2].position = { x = 2, y = 2, z = 0 }
    local other, why = F.call(JOB, "carryPutdown", 2, { kind = "vehicle", vehicleId = 10, claimKey = "veh:10:slot1" })
    check(other == nil and why == "destination_claimed", "the same slot is refused destination_claimed")
    F.advance(releaseMs() + 200)
    local item = C.items[a]
    check(item.state == "vehicle" and F.props[item.propId].attachment.parentType == "vehicle", "attached to the truck")
    check(F.props[item.propId].attachment.parentId == 10, "to vehicle 10")
    check(session(1) == nil, "player 1 empty-handed")
    -- Unloading: the author's own prompt asks for a pickup out of the truck.
    F.net("open77:actions:intent", 1, "open77_actions:carry_pickup", "item:" .. a)
    check(E.active[1] == nil or E.active[1].kind ~= "carry_pickup", "a client cannot pick out of a truck by itself")
    local refused = F.lastClient("open77:actions:refused", 1)
    check(refused and refused.payload.reason == "invalid_target", "refused invalid_target")
    F.advance(putdownMs())
    local up = F.call(JOB, "carryPickup", 1, a)
    check(up ~= nil and up.state == "presenting", "the author can take it out of the truck")
end)

run("putdown into a vehicle with a live 64-bit id (4294967297)", function()
    world()
    local VID = 4294967297
    F.vehicles[VID] = { position = { x = 2, y = 0, z = 0 }, bucket = 0 }
    local a = place()
    pickUp(1, a)
    local op, why = F.call(JOB, "carryPutdown", 1, { kind = "vehicle", vehicleId = VID, offset = { x = 0, y = -1.5, z = 1 } })
    check(op ~= nil and op.state == "presenting", "putdown into the truck started (got " .. tostring(why) .. ")")
    F.advance(releaseMs() + 200)
    local item = C.items[a]
    check(item.state == "vehicle" and F.props[item.propId].attachment.parentId == VID, "attached to vehicle " .. VID)
end)

run("a target offering the put-down: a drop zone prompt, claimed like any target", function()
    world()
    local counter = F.call(JOB, "target", { id = "counter", position = { x = 1, y = 1, z = 0.9 }, yaw = 180,
        requires = "carrying", actions = { { action = "open77_actions:carry_putdown", label = "Sell here" } } })
    check(counter == "job:counter", "drop-zone target declared")
    local id = place()
    pickUp(1, id)
    behaviour.putdown = function(ctx) return { placement = { kind = "remove" } } end
    F.net("open77:actions:intent", 1, "open77_actions:carry_putdown", "job:counter")
    local op = E.active[1]
    check(op and op.kind == "carry_putdown" and op.targetKey == "job:counter", "putdown on the counter")
    check(E.claims:holder(0, "target:job:counter") ~= nil, "the counter is claimed")
    F.advance(releaseMs() + 200)
    local ctx = calls.putdown[1]
    check(ctx and ctx.carry.destination.kind == "point" and ctx.target and ctx.target.key == "job:counter",
        "hook sees the counter as a point destination")
    check(C.items[id] == nil, "sold: the item is removed after the commit")
    F.advance(putdownMs())
    check(E.claims:count() == 0, "counter released")
    local second = place()
    pickUp(1, second)
    F.net("open77:actions:intent", 1, "open77_actions:carry_putdown", "job:nowhere")
    local refused = F.lastClient("open77:actions:refused", 1)
    check(refused and refused.payload.reason == "invalid_target", "a target that does not offer it is refused")
end)

run("destination checks", function()
    world()
    F.vehicles[10] = { position = { x = 20, y = 0, z = 0 }, bucket = 0 }
    local id = place()
    pickUp(1, id)
    local _, why = F.call(JOB, "carryPutdown", 1, { kind = "vehicle", vehicleId = 10 })
    check(why == "destination_too_far", "truck too far")
    _, why = F.call(JOB, "carryPutdown", 1, { kind = "vehicle", vehicleId = 99 })
    check(why == "vehicle_unavailable", "unknown vehicle")
    _, why = F.call(JOB, "carryPutdown", 1, { kind = "teleport" })
    check(why == "destination_invalid", "unknown destination kind")
    _, why = F.call(JOB, "carryPutdown", 1, { kind = "point", position = { x = 40, y = 0, z = 0 } })
    check(why == "destination_too_far", "point too far")
    _, why = F.call(JOB, "carryPutdown", 2, { kind = "ground" })
    check(why == "not_carrying", "not_carrying for empty hands")
    check(session(1) ~= nil, "refusals leave the carry intact")
end)

-- Live 2026-10-13: a put-down refused `no_access` by its owner reached the carrier as nothing at
-- all; the kind's `messages` now ride on its pickup and put-down actions.
run("a refused putdown carries the kind's own words", function()
    world()
    kind({ messages = { no_access = "You hold no key for that truck." } })
    local id = place()
    pickUp(1, id)
    behaviour.putdown = function() return nil, "no_access" end
    F.net("open77:actions:putdown", 1)
    F.advance(releaseMs() + 200)
    local ended = F.lastClient("open77:actions:end", 1)
    local payload = ended and ended.payload or {}
    check(payload.state == "failed" and payload.reason == "no_access", "putdown failed no_access")
    check(payload.message == "You hold no key for that truck.", "the kind's words reach the carrier")
    check(session(1) ~= nil, "still carrying")
end)

run("refused putdown resumes the carry (custody unchanged)", function()
    world()
    local id = place()
    pickUp(1, id)
    behaviour.putdown = function() return nil, "capacity_exceeded" end
    F.net("open77:actions:putdown", 1)
    local op = E.active[1]
    F.advance(releaseMs() + 200)
    check(E.ops[op.opId].state == "failed" and E.ops[op.opId].reason == "capacity_exceeded", "putdown failed")
    check(session(1) ~= nil and C.items[id].state == "carried", "still carrying")
    check(F.props[C.items[id].propId].attachment ~= nil, "still in the hands")
    check(F.anim[1] and F.anim[1].profile == "carry", "hold pose resumed")
    check(E.claims:count() == 1, "item claim kept by the session")
    check(F.carryEvents(id)[#F.carryEvents(id)] == "putdown_failed", "putdown_failed event")
    behaviour.putdown = function() return {} end
    F.net("open77:actions:putdown", 1)
    F.advance(putdownMs() + 200)
    check(session(1) == nil and C.items[id].state == "ground", "second attempt puts it down")
end)

run("pickup refused with a weapon drawn (fists included): weapon_drawn, nothing moves", function()
    world()
    local id = place()
    F.players[1].flags.weaponValid, F.players[1].flags.weaponEquipped = true, true
    F.net("open77:actions:intent", 1, "open77_actions:carry_pickup", "item:" .. id)
    F.advance(pickupMs() + 200)
    check(session(1) == nil and C.items[id].state == "ground", "not carried")
    check(#calls.pickup == 0, "no pickup hook")
    local refused = F.lastClient("open77:actions:refused", 1) or F.lastClient("open77:actions:end", 1)
    check(refused and refused.payload.reason == "weapon_drawn", "told weapon_drawn (got " ..
        tostring(refused and refused.payload.reason) .. ")")
    F.players[1].flags.weaponEquipped = false
    pickUp(1, id)
    check(session(1) ~= nil, "picked up once the weapon is away")
end)

run("refused pickup: custody unchanged, item back where it was", function()
    world()
    local id = place({ x = 1, y = 0, z = 0 })
    behaviour.pickup = function() return nil, "container_locked" end
    local op = pickUp(1, id)
    check(E.ops[op.opId].state == "failed" and E.ops[op.opId].reason == "container_locked", "pickup failed")
    local item = C.items[id]
    local prop = F.props[item.propId]
    check(item.state == "ground" and prop.attachment == nil, "detached")
    check(prop.position.x == 1 and prop.position.y == 0, "back at its original position")
    check(session(1) == nil and E.claims:count() == 0, "no session, no claim")
    check(E.targets["item:" .. id] ~= nil, "prompt restored")
end)

run("competing pickups: one winner", function()
    world()
    local id = place({ x = 0, y = 1, z = 0 })
    F.player(2, 0, 2, 0)
    F.net("open77:actions:intent", 1, "open77_actions:carry_pickup", "item:" .. id)
    F.net("open77:actions:intent", 2, "open77_actions:carry_pickup", "item:" .. id)
    local refused = F.lastClient("open77:actions:refused", 2)
    check(E.active[2] == nil and refused and (refused.payload.reason == "item_unavailable" or
        refused.payload.reason == "target_claimed"), "second picker refused")
    F.advance(pickupMs() + 200)
    check(session(1) ~= nil and session(2) == nil, "player 1 carries")
    local second = place({ x = 0, y = 1.5, z = 0 })
    F.net("open77:actions:intent", 1, "open77_actions:carry_pickup", "item:" .. second)
    refused = F.lastClient("open77:actions:refused", 1)
    check(refused and refused.payload.reason == "carrying", "one item at a time: carrying")
end)

run("a normal action is refused while carrying", function()
    world()
    local key = F.call(JOB, "define", { id = "weld", durationMs = 1000, animation = false })
    F.call(JOB, "target", { id = "n", position = { x = 0, y = 0, z = 0 }, actions = { "weld" } })
    local id = place()
    pickUp(1, id)
    local _, why = F.call(JOB, "request", 1, "weld", "n")
    check(why == "carrying", "carrying")
    check(key ~= nil, "defined")
end)

local function dropCase(name, expected, trigger)
    run("drop: " .. name, function()
        world()
        local id = place()
        pickUp(1, id)
        F.players[1].position = { x = 5, y = 5, z = 0 }
        F.players[1].heading = 0
        F.advance(200)
        trigger(id)
        F.advance(200)
        local item = C.items[id]
        check(session(1) == nil, name .. ": carry ended")
        check(item and item.state == "ground", name .. ": item on the ground")
        local prop = item and F.props[item.propId]
        check(prop and prop.attachment == nil and math.abs(prop.position.x - 5) < 0.01, name .. ": at the carrier's feet")
        check(E.claims:count() == 0, name .. ": claim released")
        check(#calls.dropped == 1 and calls.dropped[1].reason == expected,
            name .. ": dropped hook told " .. expected .. " (got " .. tostring(calls.dropped[1] and calls.dropped[1].reason) .. ")")
        check(#calls.putdown == 0, name .. ": custody unchanged (no putdown commit)")
        local clear = F.lastClient("open77:actions:carry", 1)
        check(name == "disconnect" or (clear and clear.payload.itemId == false), name .. ": client claims released")
        -- The carrier's client is told why, so it can say it in words (the item fell out of view).
        check(name == "disconnect" or (clear and clear.payload.dropped == expected and clear.payload.label == "crate"),
            name .. ": the client learns the drop and its reason")
    end)
end

dropCase("death", "dead", function() F.fire("onPlayerLifeStateChanged", "1", 3, "dead") end)
dropCase("disconnect", "disconnected", function()
    local keep = F.players[1]
    F.players[1] = nil
    F.fire("onPlayerDisconnected", "1", "connection_closed")
    keep = nil
end)
dropCase("vehicle entry", "vehicle", function() F.fire("onPlayerEnteringVehicle", "1", 7, 0) end)
dropCase("bucket change", "bucket_changed", function()
    F.fire("onPlayerBucketChange", "1", 0, 2)
end)
dropCase("combat (snapshot)", "combat", function() F.players[1].flags.aiming = true end)
dropCase("weapon drawn", "combat", function() F.fire("onPlayerWeaponChanged", "1", "1", "Items.Pistol", "true") end)
dropCase("carry pose interrupted", "animation_interrupted", function()
    F.animEnded(1, C.sessions[1].playbackId, "interrupted")
end)
dropCase("seated in a vehicle (sweep)", "vehicle", function() F.players[1].inVehicle = true end)

-- Measured 2026-10-12: a punch while carrying (unarmed melee cannot be blocked on 2.31) dropped the
-- crate; a drop in the middle of a jump must land on the ground the carrier last stood on.
run("drop in the air: on the last ground, not where the carrier hangs", function()
    world()
    local id = place()
    pickUp(1, id)
    F.players[1].position = { x = 5, y = 5, z = 10 }
    F.players[1].flags.animationValid, F.players[1].flags.grounded = true, true
    F.advance(300)
    F.players[1].position = { x = 5, y = 5, z = 10.8 }
    F.players[1].flags.grounded = false
    F.animEnded(1, C.sessions[1].playbackId, "interrupted")
    F.advance(200)
    local prop = C.items[id] and F.props[C.items[id].propId]
    check(prop and math.abs(prop.position.z - 10) < 0.01, "on the ground it left (got " ..
        tostring(prop and prop.position.z) .. ")")
end)

run("dropMessage: false leaves the words to the owner, a string rewords", function()
    world()
    kind({ dropMessage = false })
    local id = place()
    pickUp(1, id)
    F.animEnded(1, C.sessions[1].playbackId, "interrupted")
    F.advance(200)
    local clear = F.lastClient("open77:actions:carry", 1)
    check(clear and clear.payload.dropped == "animation_interrupted" and clear.payload.message == false,
        "silenced by the kind")
    kind({ dropMessage = "Your %s hit the dirt." })
    id = place()
    pickUp(1, id)
    F.animEnded(1, C.sessions[1].playbackId, "interrupted")
    F.advance(200)
    clear = F.lastClient("open77:actions:carry", 1)
    check(clear and clear.payload.message == "Your %s hit the dirt.", "reworded by the kind")
end)

-- Measured 2026-10-12: a Warden teleport ends the hold pose with `player_unavailable` while
-- the carrier stays connected. The carry must survive the move, not drop as "disconnected".
run("teleport: hold suspended then resumed, custody kept", function()
    world()
    local id = place()
    pickUp(1, id)
    local before = C.sessions[1].playbackId
    F.animEnded(1, before, "player_unavailable")
    check(session(1) ~= nil and C.items[id].state == "carried", "still carried after player_unavailable")
    check(#calls.dropped == 0, "no drop on a server move")
    F.advance(300)
    local s = session(1)
    check(s ~= nil and s.playbackId ~= nil and s.playbackId ~= before and s.resumeDeadline == nil,
        "hold replayed once the player is back")
    check(#calls.putdown == 0 and C.items[id].state == "carried", "custody unchanged")
end)

run("player_unavailable for a carrier who left: dropped as disconnected", function()
    world()
    local id = place()
    pickUp(1, id)
    local playback = C.sessions[1].playbackId
    F.players[1] = nil
    F.animEnded(1, playback, "player_unavailable")
    F.advance(300)   -- the server roster is cached for 250 ms
    check(session(1) == nil, "carry ended")
    check(#calls.dropped == 1 and calls.dropped[1].reason == "disconnected", "dropped as disconnected")
end)

run("drop: owner stop removes the item", function()
    world()
    local id = place()
    pickUp(1, id)
    local propId = C.items[id].propId
    F.generations[JOB] = 0
    F.fire("onResourceStop", JOB)
    check(session(1) == nil and C.items[id] == nil and F.props[propId] == nil, "dropped then removed")
    check(E.claims:count() == 0, "claims released")
end)

run("drop: resource stop", function()
    world()
    local id = place()
    pickUp(1, id)
    F.fire("onResourceStop", "open77_actions")
    check(session(1) == nil and C.items[id].state == "ground", "dropped on stop")
    local clear = F.lastClient("open77:actions:carry", 1)
    check(clear and clear.payload.itemId == false, "client released")
end)

run("putdown interrupted by death drops instead of resuming", function()
    world()
    local id = place()
    pickUp(1, id)
    F.net("open77:actions:putdown", 1)
    local op = E.active[1]
    F.advance(300)
    F.fire("onPlayerLifeStateChanged", "1", 3, "dead")
    check(E.ops[op.opId].state == "cancelled" and E.ops[op.opId].reason == "dead", "putdown cancelled: dead")
    check(session(1) == nil and C.items[id].state == "ground", "dropped")
    check(#calls.putdown == 0, "no custody change")
end)

run("stale notices: the hold's end after the putdown started changes nothing", function()
    world()
    local id = place()
    local pickupOp = pickUp(1, id)
    local holdPlayback = pickupOp.playbackId
    F.net("open77:actions:putdown", 1)
    F.animEnded(1, holdPlayback, "replaced")
    local op = E.active[1]
    check(op and op.state == "presenting" and session(1) ~= nil, "putdown still running, carry intact")
    F.advance(putdownMs() + 200)
    check(C.items[id].state == "ground", "put down normally")
    F.animEnded(1, holdPlayback, "interrupted")
    check(#calls.dropped == 0, "no phantom drop from the old playback")
    local again = F.call(JOB, "carryPickup", 2, "it-gone-1")
    check(again == nil, "an unknown item id is refused")
end)

run("first-person placement refused: attach retried without it", function()
    world()
    local id = place()
    F.attachRefuse = { reason = "invalid_attachment", count = 1 }
    pickUp(1, id)
    local prop = F.props[C.items[id].propId]
    check(session(1) ~= nil and prop.attachment ~= nil and prop.attachment.firstPerson == nil,
        "carried with the third-person binding")
end)

run("attach refused: attach_failed, item back on the ground", function()
    world()
    local id = place()
    F.attachRefuse = { reason = "invalid_prop_id", count = 2 }
    local op = pickUp(1, id)
    check(E.ops[op.opId].state == "cancelled" and E.ops[op.opId].reason == "attach_failed", "attach_failed")
    check(session(1) == nil and C.items[id].state == "ground", "ground")
end)

run("projection refused after commit: retried, then the ground; the commit stands", function()
    world()
    F.vehicles[10] = { position = { x = 2, y = 0, z = 0 }, bucket = 0 }
    local id = place()
    pickUp(1, id)
    local op = F.call(JOB, "carryPutdown", 1, { kind = "vehicle", vehicleId = 10 })
    F.advance(releaseMs() - 100)
    F.attachRefuse = { reason = "invalid_attachment_parent", count = 10 }
    F.advance(1000)
    check(E.ops[op.opId].state == "committed" and #calls.putdown == 1, "committed once")
    check(C.items[id].state == "ground", "fell back to the ground after the retries")
    local events = F.carryEvents(id)
    check(events[#events] == "projection_failed", "projection_failed reported")
end)

run("epoch guard on a carry: the job changed, the item goes down", function()
    world()
    kind({ epochs = { event = "rp_jobs:workEpoch" } })
    TriggerEvent("rp_jobs:workEpoch", 1, 1, "duty")
    local id = place()
    pickUp(1, id)
    check(session(1) ~= nil, "carrying under epoch 1")
    TriggerEvent("rp_jobs:workEpoch", 1, 2, "duty")
    check(session(1) == nil and C.items[id].state == "ground", "dropped on the epoch change")
    check(calls.dropped[1] and calls.dropped[1].reason == "stale_job_epoch", "reason stale_job_epoch")
end)

run("carryRemove and carryDrop belong to the owner", function()
    world()
    local id = place()
    local _, why = F.call("other", "carryRemove", id)
    check(why == "not_owner", "another resource cannot remove")
    pickUp(1, id)
    _, why = F.call("other", "carryDrop", 1)
    check(why == "not_owner", "another resource cannot force a drop")
    check(F.call(JOB, "carryDrop", 1, "cancelled") == true, "the owner can")
    check(F.call(JOB, "carryRemove", id) == true and C.items[id] == nil, "the owner removes")
    _, why = F.call(JOB, "carryRemove", id)
    check(why == "item_unavailable", "item_unavailable after removal")
end)

run("no scheduled thread raised during the suite", function()
    local clean, detail = F.noThreadErrors()
    check(clean, "thread errors: " .. detail)
end)

TestResult = { passed = passed, failed = #failures, failures = failures }
