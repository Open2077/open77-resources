-- =============================================================================
-- open77_actions -- tests/prompt_test.lua
-- =============================================================================
-- The client path from a server point target to the intent the server
-- receives, with no stub between the two resources that matter: the REAL
-- `open77_interactions/client/main.lua` and the REAL
-- `open77_actions/client/main.lua`, each in its own environment, joined by a
-- small host that keeps the platform's contracts:
--
--   * `Open77.exports.call` runs the callee with GetInvokingResource() = the
--     calling resource (ResourceHost.cpp: the ExportRequest records
--     `context->resource->definition.name` as `caller`, and ResumeTask sets
--     `invokingResource` from it for the callee's task);
--   * `TriggerEvent` reaches every running resource's handlers, payload copied
--     (ResourceHost.cpp QueueEvent);
--   * `Open77.anchors.frame()` answers the projection of each anchor from a
--     first-person camera: eye above the feet, yaw/pitch, 50 degree vertical
--     field of view at 16:9 -- the same normalised x/y, onScreen, depth and
--     camera distance WorldAnchors.cpp `Project` publishes;
--   * `Open77.input.isDown` answers the key held at the instant it is asked
--     (WebUiService::KeyDown reads a state, not a latch).
--
-- The target is rp_salvage's wreck node as the server sends it: a point at the
-- KNEELING SPOT, on the ground (`/pos` readings), three choices E/F/R, reach
-- 2.5 m (shared/model.lua normalizeTarget + engine.lua qualification).
--
-- Live symptom this pins (integrator, 2026-10-12): the card "Cut (torch) +2
-- more 1.5 m" drawn just under the crosshair, E pressed, no intent and no
-- refusal on the server. The card is drawn for the best candidate whether or
-- not it is active; only an ACTIVE candidate fires, and a prompt that
-- requires look-at is active only while its anchor is within `focusRadius`
-- (0.18) of the screen centre -- which a point on the floor at the player's
-- feet is only when the player stares straight down at it.
--
-- The same host also replays the carry's control claims (test 11): the
-- 2026-10-12 live findings that `Attack` alone let an empty-handed carrier
-- punch -- and drop the crate -- and that walk mode alone let him sprint.
--
-- Run from the repository root with a standalone Lua 5.4:
--   lua resources/system/open77_actions/tests/prompt_test.lua
-- or through ActionsLuaTests.ClientPromptSuitePasses.
-- =============================================================================

local passed, failures = 0, {}
local function check(cond, msg)
    if cond then passed = passed + 1 else failures[#failures + 1] = msg or "assertion failed" end
end

local function readFile(path)
    if __open77_test_read then
        local source, why = __open77_test_read(path)
        if not source then error(why, 2) end
        return source
    end
    local handle = assert(io.open("resources/" .. path, "rb"))
    local source = handle:read("a")
    handle:close()
    return source
end

local function deepCopy(value, seen)
    local kind = type(value)
    if kind == "function" or kind == "userdata" or kind == "thread" then
        error("payload not serializable (" .. kind .. ")", 3)
    end
    if kind ~= "table" then return value end
    seen = seen or {}
    if seen[value] then error("cyclic payload", 3) end
    seen[value] = true
    local out = {}
    for k, v in pairs(value) do out[deepCopy(k, seen)] = deepCopy(v, seen) end
    seen[value] = nil
    return out
end

-- ---------------------------------------------------------------------------
-- The host
-- ---------------------------------------------------------------------------
local function newHost(options)
    options = options or {}
    local host = {
        now = 0.0, frame = 0, frameSeconds = options.frameSeconds or (1 / 30),
        tasks = {}, vms = {}, order = {}, errors = {}, intents = {}, serverEvents = {}, notices = {},
        keys = {}, captured = false, blocks = {}, jumps = {},
        anchors = {}, nextAnchor = 1,
        player = { x = 0, y = 0, z = 0 }, localId = options.localId or 7,
        camera = { yaw = 0, pitch = 0, eye = 1.5, vfov = 50, aspect = 16 / 9 },
    }

    function host:spawn(vm, fn, ...)
        local args = table.pack(...)
        local co = coroutine.create(function() return fn(table.unpack(args, 1, args.n)) end)
        self.tasks[#self.tasks + 1] = { vm = vm, co = co, wakeAt = self.now }
    end

    -- One host tick: every due task resumes once, like ResourceHost::Tick.
    function host:step()
        self.frame = self.frame + 1
        self.now = self.now + self.frameSeconds
        local current = self.tasks
        self.tasks = {}
        local kept = {}
        for _, task in ipairs(current) do
            if task.wakeAt <= self.now + 1e-9 then
                local ok, ms = coroutine.resume(task.co)
                if not ok then
                    self.errors[#self.errors + 1] = task.vm.name .. ": " .. tostring(ms)
                elseif coroutine.status(task.co) ~= "dead" then
                    task.wakeAt = self.now + math.max(0, tonumber(ms) or 0) / 1000
                    kept[#kept + 1] = task
                end
            else
                kept[#kept + 1] = task
            end
        end
        for _, task in ipairs(self.tasks) do kept[#kept + 1] = task end
        self.tasks = kept
    end

    function host:run(seconds)
        local frames = math.max(1, math.floor(seconds / self.frameSeconds + 0.5))
        for _ = 1, frames do self:step() end
    end

    function host:press(key, holdSeconds)
        self.keys[key] = true
        self:run(holdSeconds)
        self.keys[key] = nil
        self:run(0.5)
    end

    -- Local events: every running resource's handlers, each with its own copy.
    function host:emit(event, ...)
        local args = table.pack(...)
        for _, name in ipairs(self.order) do
            local vm = self.vms[name]
            for _, handler in ipairs(vm.handlers) do
                if handler.event == event then
                    self:spawn(vm, handler.fn, table.unpack(deepCopy(args), 1, args.n))
                end
            end
        end
    end

    -- A server -> client net event, to network handlers only.
    function host:toClient(event, ...)
        local args = table.pack(...)
        for _, name in ipairs(self.order) do
            local vm = self.vms[name]
            for _, handler in ipairs(vm.handlers) do
                if handler.network and handler.event == event then
                    self:spawn(vm, handler.fn, table.unpack(deepCopy(args), 1, args.n))
                end
            end
        end
    end

    function host:invoke(caller, targetName, exportName, args)
        local target = self.vms[targetName]
        if not target then error("export_resource_unavailable", 2) end
        local fn = target.exports[exportName]
        if not fn then error("export_not_found", 2) end
        local saved, savedGeneration = target.invoking, target.invokingGeneration
        target.invoking, target.invokingGeneration = caller.name, caller.generation
        local results = table.pack(pcall(fn, table.unpack(deepCopy(args), 1, args.n)))
        target.invoking, target.invokingGeneration = saved, savedGeneration
        if not results[1] then error(results[2], 2) end
        local out = {}
        for index = 2, results.n do out[index - 1] = deepCopy(results[index]) end
        return table.unpack(out, 1, results.n - 1)
    end

    -- First-person camera: eye above the feet, yaw 0 faces +Y (counter-clockwise),
    -- negative pitch looks down.
    function host:eye()
        local p, c = self.player, self.camera
        return { x = p.x, y = p.y, z = p.z + c.eye }
    end

    function host:project(point)
        local c, e = self.camera, self:eye()
        local yaw, pitch = math.rad(c.yaw), math.rad(c.pitch)
        local fx, fy, fz = -math.sin(yaw) * math.cos(pitch), math.cos(yaw) * math.cos(pitch), math.sin(pitch)
        local rx, ry = math.cos(yaw), math.sin(yaw)
        local ux, uy, uz = math.sin(yaw) * math.sin(pitch), -math.cos(yaw) * math.sin(pitch), math.cos(pitch)
        local dx, dy, dz = point.x - e.x, point.y - e.y, point.z - e.z
        local depth = dx * fx + dy * fy + dz * fz
        local distance = math.sqrt(dx * dx + dy * dy + dz * dz)
        if depth <= 0.05 then return { projected = false, onScreen = false, depth = depth, distance = distance } end
        local tanV = math.tan(math.rad(c.vfov / 2))
        local tanH = tanV * c.aspect
        local x = 0.5 + 0.5 * ((dx * rx + dy * ry) / depth) / tanH
        local y = 0.5 - 0.5 * ((dx * ux + dy * uy + dz * uz) / depth) / tanV
        return { projected = true, x = x, y = y, depth = depth, distance = distance,
            onScreen = x >= 0 and x <= 1 and y >= 0 and y <= 1 }
    end

    -- Points the camera at a world point (the "look straight at it" control).
    function host:lookAt(point)
        local e = self:eye()
        local dx, dy, dz = point.x - e.x, point.y - e.y, point.z - e.z
        self.camera.yaw = math.deg(math.atan(-dx, dy))
        self.camera.pitch = math.deg(math.atan(dz, math.sqrt(dx * dx + dy * dy)))
    end

    -- The one card the plugin draws: the visible card-style anchor.
    function host:card()
        for _, anchor in pairs(self.anchors) do
            if anchor.render == "card" and anchor.visible and anchor.presentation and anchor.presentation.label then
                local row = self:project(anchor.position)
                return { label = anchor.presentation.label, key = anchor.presentation.key,
                    sublabel = anchor.presentation.sublabel, color = anchor.presentation.color,
                    anchor = anchor.position, onScreen = row.onScreen, x = row.x, y = row.y,
                    distance = row.distance }
            end
        end
        return nil
    end

    local function anchorApi()
        return {
            create = function(o)
                local id = host.nextAnchor
                host.nextAnchor = id + 1
                host.anchors[id] = { id = id, position = deepCopy(o.position), entity = o.entity,
                    render = o.render, visible = o.visible ~= false, maxDistance = o.maxDistance,
                    presentation = deepCopy(o.presentation) }
                return id
            end,
            update = function(id, patch)
                local anchor = host.anchors[tonumber(id)]
                if not anchor then return nil, "anchor_not_found" end
                if patch.position ~= nil then anchor.position = deepCopy(patch.position) end
                if patch.visible ~= nil then anchor.visible = patch.visible end
                if patch.maxDistance ~= nil then anchor.maxDistance = patch.maxDistance end
                if patch.presentation ~= nil then anchor.presentation = deepCopy(patch.presentation) end
                return true
            end,
            remove = function(id) host.anchors[tonumber(id)] = nil; return true end,
            clear = function() host.anchors = {} end,
            frame = function()
                local rows = {}
                for id, anchor in pairs(host.anchors) do
                    if anchor.position then
                        local row = host:project(anchor.position)
                        rows[#rows + 1] = { id = tostring(id), projected = row.projected, onScreen = row.onScreen,
                            x = row.x, y = row.y, depth = row.depth, distance = row.distance,
                            resolved = deepCopy(anchor.position) }
                    end
                end
                return rows
            end,
        }
    end

    local function open77For(vm)
        return {
            time = { monotonic = function() return host.now end },
            log = { warn = function() end, info = function() end },
            character = {
                position = function() return host.player.x, host.player.y, host.player.z end,
                state = function()
                    return { attached = true, position = { x = host.player.x, y = host.player.y, z = host.player.z } }
                end,
            },
            input = {
                isDown = function(key) return host.keys[key] == true end,
                isCaptured = function() return host.captured end,
                setActionBlocked = function(action, blocked)
                    host.blocks[#host.blocks + 1] = { action = action, blocked = blocked }
                    return true
                end,
                registerKeyMapping = function() return true end,
                keyFor = function() return "G" end,
            },
            players = {
                allowJump = function(allowed) host.jumps[#host.jumps + 1] = allowed; return true end,
                localId = function() return host.localId end,
            },
            movement = { setWalkMode = function() return true end },
            hud = { notify = function(text) host.notices[#host.notices + 1] = text end },
            resource = { generation = function(name) return host.vms[name] and host.vms[name].generation or nil end },
            camera = { project = function(point) return host:project(point) end },
            anchors = anchorApi(),
            exports = {
                call = function(target, exportName, ...)
                    if not host.vms[target] then return nil, "export_resource_unavailable" end
                    local args = table.pack(...)
                    local promise = {}
                    function promise.await() return host:invoke(vm, target, exportName, args) end
                    return promise
                end,
                callSync = function(target, exportName, ...)
                    return host:invoke(vm, target, exportName, table.pack(...))
                end,
            },
        }
    end

    -- `paths` in manifest order: shared scripts first, as the client host does.
    function host:load(name, paths)
        local vm = { name = name, generation = 1, handlers = {}, exports = {} }
        local env = setmetatable({}, { __index = _G })
        env.GetCurrentResourceName = function() return name end
        env.GetInvokingResource = function() return vm.invoking end
        env.GetInvokingResourceGeneration = function() return vm.invoking and vm.invokingGeneration or nil end
        env.GetResourceState = function(other) return host.vms[other] and "running" or "missing" end
        env.exports = function(exportName, fn) vm.exports[exportName] = fn end
        env.AddEventHandler = function(event, fn) vm.handlers[#vm.handlers + 1] = { event = event, fn = fn } end
        env.RegisterNetEvent = function(event, fn)
            vm.handlers[#vm.handlers + 1] = { event = event, fn = fn, network = true }
        end
        env.TriggerEvent = function(event, ...) host:emit(event, ...); return true end
        env.TriggerServerEvent = function(event, ...)
            local args = deepCopy(table.pack(...))
            host.serverEvents[#host.serverEvents + 1] = { from = name, event = event, args = args }
            if event == "open77:actions:intent" then
                host.intents[#host.intents + 1] = { action = args[1], target = args[2] }
            end
            return true
        end
        env.CreateThread = function(fn) host:spawn(vm, fn) end
        env.Wait = function(ms) coroutine.yield(ms or 0) end
        env.WebUI = { create = function()
            return { on = function() end, send = function() return true end }
        end }
        env.Open77 = open77For(vm)
        env.print = function() end
        vm.env = env
        host.vms[name] = vm
        host.order[#host.order + 1] = name
        for _, path in ipairs(type(paths) == "table" and paths or { paths }) do
            assert(load(readFile(path), "@" .. path, "t", env))()
        end
        return vm
    end

    return host
end

-- ---------------------------------------------------------------------------
-- The target, exactly as the server half puts it on the wire
-- ---------------------------------------------------------------------------
local modelEnv = setmetatable({}, { __index = _G })
assert(load(readFile("system/open77_actions/shared/model.lua"), "@open77_actions/shared/model.lua", "t", modelEnv))()
local M = modelEnv.Open77ActionsModel

local SPOT = { x = 1368.0, y = -1690.8, z = 49.3 }   -- rp_salvage "thorton": walked kneeling spot

-- `extra` adds definition fields (promptHeight, lookAt); `legacy` drops the
-- prompt fields from the wire, as a server half older than this client sends.
local function salvageNodeWire(extra, legacy)
    local def = {
        id = "node_thorton", position = SPOT, yaw = 180.0, bucket = 0, label = "Burnt-out Thorton",
        distance = 2.5, markerDistance = 12.0, requires = "empty",
        actions = {
            { action = "cut", label = "Cut (torch)" },
            { action = "pry", label = "Pry (crowbar)" },
            { action = "inspect", label = "Check the haul" },
        },
    }
    for k, v in pairs(extra or {}) do def[k] = v end
    local target = assert(M.normalizeTarget(def))
    -- engine.lua addTarget: key = owner:id, choices qualified against the owner.
    target.key = "rp_salvage:node_thorton"
    for _, choice in ipairs(target.actions) do choice.action = "rp_salvage:" .. choice.action end
    -- server/main.lua clientTarget (its source is checked against this copy below)
    local wire = {
        key = target.key, position = target.position, bucket = target.bucket,
        label = target.label, description = target.description, distance = target.distance,
        markerDistance = target.markerDistance, marker = target.marker, color = target.color,
        icon = target.icon, requires = target.requires, choices = target.actions,
    }
    if not legacy then wire.promptHeight, wire.lookAt, wire.hideFor = target.promptHeight, target.lookAt, target.hideFor end
    return wire
end

local function newScene(options)
    options = options or {}
    local host = newHost(options)
    host:load("open77_interactions", "system/open77_interactions/client/main.lua")
    host:load("open77_actions", { "system/open77_actions/shared/model.lua", "system/open77_actions/client/main.lua" })
    host:emit("onClientResourceStart", "open77_interactions")
    host:emit("onClientResourceStart", "open77_actions")
    host:run(1.2)   -- the actions client's first Wait(1000), then its sync
    host:toClient("open77:actions:targets", { generation = 1, reset = true,
        upsert = options.targets or { salvageNodeWire(options.target, options.legacy) }, remove = {} })
    return host
end

-- Player north of the spot, facing the wreck stack (yaw 180 = facing -y).
local function stand(host, northOfSpot, pitch)
    host.player = { x = SPOT.x, y = SPOT.y + northOfSpot, z = SPOT.z }
    host.camera.yaw, host.camera.pitch = 180.0, pitch
end

local function intentsSince(host, mark)
    local out = {}
    for index = mark + 1, #host.intents do out[#out + 1] = host.intents[index] end
    return out
end

local function run(name, fn)
    local ok, err = pcall(fn)
    if not ok then failures[#failures + 1] = name .. ": runtime error: " .. tostring(err) end
end

local BRIGHT, DIM = "#F2F6F8", "#8D99A8"   -- open77_interactions pushNativeCard: active / not active

-- ---------------------------------------------------------------------------
-- 1. The live scene: standing at the spot, card drawn just below the
--    crosshair at ~1.5 m, E held 80 ms and 300 ms. The prompt must fire.
-- ---------------------------------------------------------------------------
run("card under the crosshair fires on E", function()
    for _, holdSeconds in ipairs({ 0.08, 0.3 }) do
        local host = newScene()
        stand(host, 0.3, -60.0)
        host:run(1.5)
        -- The scene as reported: the camera ~1.5 m from the floor point, which
        -- projects on screen but well outside the 0.18 focus radius.
        local spot = host:project(SPOT)
        check(spot.onScreen and spot.y > 0.5 + 0.18 and math.abs(spot.distance - 1.5) < 0.1,
            ("scene: the floor point is on screen, below the focus radius, ~1.5 m away (y=%.2f d=%.2f)")
                :format(spot.y or -1, spot.distance))
        local card = host:card()
        check(card ~= nil, "a card is drawn at the spot")
        if card then
            check(card.label == "Cut (torch)", "the card names the first choice, got " .. tostring(card.label))
            check(card.key == "E", "the card's keycap is E")
            check(card.onScreen, "the card is on screen")
            check(card.color == BRIGHT, ("the card the player sees is ACTIVE (bright), got %s at y=%.2f")
                :format(tostring(card.color), card.y or -1))
        end
        local mark = #host.intents
        host:press("E", holdSeconds)
        local sent = intentsSince(host, mark)
        check(#sent == 1, ("E held %d ms sends exactly one intent, sent %d"):format(holdSeconds * 1000, #sent))
        if sent[1] then
            check(sent[1].action == "rp_salvage:cut", "E is the first choice: " .. tostring(sent[1].action))
            check(sent[1].target == "rp_salvage:node_thorton", "the intent names the target key")
        end
        check(#host.errors == 0, "no VM error: " .. table.concat(host.errors, " | "))
    end
end)

-- ---------------------------------------------------------------------------
-- 2. Walking up to the node with a natural gaze (15 degrees down, 1.5 m
--    away): the card must be on screen and live -- the B5/A5 run reported
--    "the lab node card did not appear" for a node 1.2 m ahead at foot level.
-- ---------------------------------------------------------------------------
run("approach with a natural gaze shows a live card", function()
    local host = newScene()
    stand(host, 1.5, -15.0)
    host:run(1.5)
    local card = host:card()
    check(card ~= nil and card.onScreen, "the card is on screen while walking up to the node")
    check(card ~= nil and card.color == BRIGHT, "and it is active: " .. tostring(card and card.color))
    local mark = #host.intents
    host:press("E", 0.3)
    check(#intentsSince(host, mark) == 1, "E fires from the approach")
end)

-- ---------------------------------------------------------------------------
-- 3. Control: looking straight at the anchor. Holds before and after the fix,
--    and proves the rest of the chain -- owner recorded through the export
--    bridge, the choice event crossing resources, one intent per press, one
--    key per choice (E/F/R), no selection model behind "+2 more".
-- ---------------------------------------------------------------------------
run("looking straight at the anchor: owner, event and keys", function()
    local host = newScene()
    stand(host, 0.8, -30.0)
    host:run(1.0)
    local anchor
    for _, a in pairs(host.anchors) do anchor = a end
    check(anchor ~= nil, "the prompt has an anchor")
    if not anchor then return end
    host:lookAt(anchor.position)
    host:run(1.0)
    local card = host:card()
    check(card ~= nil and card.color == BRIGHT, "a focused card is active")
    check(card ~= nil and card.sublabel ~= nil and card.sublabel:find("+2 more", 1, true) ~= nil,
        "the card says +2 more")
    -- Hypothesis 1 (owner mismatch) refuted: the prompt created through
    -- Open77.exports.call is recorded under the calling resource's name, the
    -- one the choice handler compares against.
    local mine = host:invoke(host.vms.open77_actions, "open77_interactions", "all", table.pack())
    check(type(mine) == "table" and #mine == 1 and mine[1].owner == "open77_actions",
        "the prompt's owner is open77_actions, got " .. tostring(mine and mine[1] and mine[1].owner))
    for _, case in ipairs({ { "E", "rp_salvage:cut" }, { "F", "rp_salvage:pry" }, { "R", "rp_salvage:inspect" } }) do
        local mark = #host.intents
        host:press(case[1], 0.3)
        local sent = intentsSince(host, mark)
        check(#sent == 1, case[1] .. " sends exactly one intent, sent " .. #sent)
        check(sent[1] ~= nil and sent[1].action == case[2], case[1] .. " -> " .. case[2] .. ", got " ..
            tostring(sent[1] and sent[1].action))
    end
    check(#host.errors == 0, "no VM error: " .. table.concat(host.errors, " | "))
end)

-- ---------------------------------------------------------------------------
-- 4. Reach: the client gate matches the server's 3D distance to the target
--    point (engine.lua validate: distance <= maxDistance) on level ground.
-- ---------------------------------------------------------------------------
run("reach matches the server gate on level ground", function()
    local inside = newScene()
    stand(inside, 2.4, -20.0)
    inside:run(1.5)
    local mark = #inside.intents
    inside:press("E", 0.3)
    check(#intentsSince(inside, mark) == 1, "2.4 m from the spot (server reach 2.5 m) fires")

    local outside = newScene()
    stand(outside, 2.7, -20.0)
    outside:run(1.5)
    mark = #outside.intents
    outside:press("E", 0.3)
    check(#intentsSince(outside, mark) == 0, "2.7 m from the spot does not fire")
    local card = outside:card()
    check(card == nil or card.color == DIM, "out of reach the card is drawn dim, if at all")
end)

-- ---------------------------------------------------------------------------
-- 5. The lab's frame rate: two clients ran at ~8 fps (125 ms per host tick).
--    A 300 ms hold spans several ticks and must fire exactly once.
-- ---------------------------------------------------------------------------
run("8 fps: a 300 ms press fires once", function()
    local host = newScene({ frameSeconds = 0.125 })
    stand(host, 0.3, -60.0)
    host:run(2.0)
    local mark = #host.intents
    host:press("E", 0.3)
    check(#intentsSince(host, mark) == 1, "one intent at 8 fps")
end)

-- ---------------------------------------------------------------------------
-- 6. A captured keyboard (a focused page, the pause menu) never fires.
-- ---------------------------------------------------------------------------
run("captured input does not fire", function()
    local host = newScene()
    stand(host, 0.3, -60.0)
    host:run(1.5)
    host.captured = true
    local mark = #host.intents
    host:press("E", 0.3)
    check(#intentsSince(host, mark) == 0, "no intent while input is captured")
end)

-- ---------------------------------------------------------------------------
-- 7. A server half older than this client sends no prompt fields: the client
--    default alone fixes the live scene.
-- ---------------------------------------------------------------------------
run("legacy wire: the client default fixes the scene", function()
    local host = newScene({ legacy = true })
    stand(host, 0.3, -60.0)
    host:run(1.5)
    local mark = #host.intents
    host:press("E", 0.3)
    check(#intentsSince(host, mark) == 1, "E fires with a wire that has no promptHeight/lookAt")
end)

-- ---------------------------------------------------------------------------
-- 8. `lookAt = true`: the author's opt-in for spots packed closer than their
--    reach. In reach with the card low on screen, E does nothing until the
--    crosshair is on the card; without the opt-in the same card fires.
-- ---------------------------------------------------------------------------
run("lookAt = true requires the crosshair on the card", function()
    local strict = newScene({ target = { lookAt = true } })
    stand(strict, 1.5, 5.0)
    strict:run(1.5)
    local card = strict:card()
    check(card ~= nil and card.onScreen and card.y > 0.5 + 0.18, "scene: the card is on screen, low, off the crosshair")
    check(card ~= nil and card.color == DIM, "lookAt: the off-crosshair card is dim")
    local mark = #strict.intents
    strict:press("E", 0.3)
    check(#intentsSince(strict, mark) == 0, "lookAt: E off the crosshair does nothing")
    local anchor
    for _, a in pairs(strict.anchors) do anchor = a end
    if anchor then strict:lookAt(anchor.position) end
    strict:run(1.0)
    mark = #strict.intents
    strict:press("E", 0.3)
    check(#intentsSince(strict, mark) == 1, "lookAt: E on the crosshair fires")

    local loose = newScene()
    stand(loose, 1.5, 5.0)
    loose:run(1.5)
    mark = #loose.intents
    loose:press("E", 0.3)
    check(#intentsSince(loose, mark) == 1, "default: the same low card fires")
end)

-- ---------------------------------------------------------------------------
-- 9. The prompt fields: carried to the anchor, bounded by the model.
-- ---------------------------------------------------------------------------
run("promptHeight and lookAt are carried and bounded", function()
    local low = newScene({ target = { promptHeight = 0.4 } })
    stand(low, 1.0, -30.0)
    low:run(1.5)
    local anchor
    for _, a in pairs(low.anchors) do anchor = a end
    check(anchor ~= nil and math.abs(anchor.position.z - (SPOT.z + 0.4)) < 1e-6,
        "promptHeight 0.4 puts the card 0.4 m above the point")
    local defaults = assert(M.normalizeTarget({ id = "a", position = SPOT, actions = { "x" } }))
    check(defaults.promptHeight == 1.0 and defaults.lookAt == false, "defaults: 1.0 m, no look-at")
    local refused = { { promptHeight = -0.1 }, { promptHeight = 3.5 }, { promptHeight = "high" }, { lookAt = "yes" } }
    for _, extra in ipairs(refused) do
        local def = { id = "a", position = SPOT, actions = { "x" } }
        for k, v in pairs(extra) do def[k] = v end
        local target, reason = M.normalizeTarget(def)
        check(target == nil and reason == "invalid_target", "refused: " .. tostring(next(extra)))
    end
    local server = readFile("system/open77_actions/server/main.lua")
    check(server:find("promptHeight = target.promptHeight, lookAt = target.lookAt", 1, true) ~= nil and
        server:find("hideFor = target.hideFor", 1, true) ~= nil,
        "server/main.lua clientTarget sends the prompt fields this suite's wire copy sends")
end)

-- ---------------------------------------------------------------------------
-- 10. A reach above the marker distance used to be refused by
--     open77_interactions (`invalid_show_distance`) and the target had no
--     prompt at all, silently. The marker distance is raised to the reach.
-- ---------------------------------------------------------------------------
run("a long reach still gets a prompt", function()
    local host = newScene({ target = { distance = 25.0, markerDistance = 12.0 } })
    stand(host, 1.0, -30.0)
    host:run(1.5)
    local mine = host:invoke(host.vms.open77_actions, "open77_interactions", "all", table.pack())
    check(type(mine) == "table" and #mine == 1, "the 25 m-reach target has its prompt")
    if mine and mine[1] then
        check(mine[1].distance <= 25.0 and mine[1].showDistance >= mine[1].distance,
            "reach within the service's bound, marker distance at least the reach")
    end
end)

-- ---------------------------------------------------------------------------
-- 11. The carry's control claims. `attack` is "no fighting": Attack (firing)
--     AND Melee, claimed together and given back together. Measured live
--     2026-10-12 before the Melee lever existed: an empty-handed carrier
--     clicked, V drew his fists and punched, the crate fell
--     (`animation_interrupted`).
-- ---------------------------------------------------------------------------
local function lastBlock(host, action)
    for index = #host.blocks, 1, -1 do
        if host.blocks[index].action == action then return host.blocks[index].blocked end
    end
    return nil
end

run("a carry claims Attack and Melee together and gives both back", function()
    local host = newScene()
    local mark = #host.blocks
    host:toClient("open77:actions:carry", { generation = 1, itemId = "crate-1", sessionId = "carry-1",
        label = "Scrap crate", claims = { walkSpeed = 1.2, jump = true, attack = true, sprint = true } })
    host:run(0.2)
    check(lastBlock(host, "Attack") == true, "carrying claims Attack")
    check(lastBlock(host, "Melee") == true, "carrying claims Melee -- a punch drops the crate")
    check(lastBlock(host, "Sprint") == true, "carrying claims Sprint -- walk mode alone does not cap it")
    check(lastBlock(host, "Movement") == nil, "a carry leaves walking alone")
    check(host.jumps[#host.jumps] == false, "carrying takes jumping away")
    local claimed = #host.blocks - mark
    check(claimed == 3, ("exactly three action claims on pickup, got %d"):format(claimed))

    host:toClient("open77:actions:carry", { generation = 1, itemId = false, sessionId = "carry-1" })
    host:run(0.2)
    check(lastBlock(host, "Attack") == false, "putting down releases Attack")
    check(lastBlock(host, "Melee") == false, "putting down releases Melee")
    check(lastBlock(host, "Sprint") == false, "putting down releases Sprint")
    check(host.jumps[#host.jumps] == true, "and gives jumping back")
    check(#host.errors == 0, "no VM error: " .. table.concat(host.errors, " | "))
end)

-- The real pickup order (server/carry.lua startSession, engine.lua
-- endPresentation): the pickup operation presents, the commit starts the carry
-- session, then the operation ends. Until 2026-10-12 the end released every
-- claim, the carry's included, because applyClaims walked `{ current, carry }`
-- with ipairs and stopped at the nil operation slot.
run("pickup order: the operation ends, the carry keeps its claims", function()
    local host = newScene()
    host:toClient("open77:actions:present", { generation = 1, opId = "act-00000001", claims = { move = true, attack = true } })
    host:run(0.2)
    host:toClient("open77:actions:carry", { generation = 1, itemId = "crate-1", sessionId = "act-00000001",
        label = "Scrap crate", claims = { walkSpeed = 1.2, jump = true, attack = true, sprint = true } })
    host:run(0.2)
    local mark = #host.blocks
    host:toClient("open77:actions:end", { generation = 1, opId = "act-00000001", state = "committed" })
    host:run(0.2)
    check(lastBlock(host, "Movement") == false, "the operation's Movement claim ends with it")
    local touched = false
    for index = mark + 1, #host.blocks do
        local row = host.blocks[index]
        if row.action == "Attack" or row.action == "Melee" or row.action == "Sprint" then touched = true end
    end
    check(not touched, "the carry still holds Attack, Melee and Sprint after the operation ends")
    check(lastBlock(host, "Attack") == true and lastBlock(host, "Melee") == true and
        lastBlock(host, "Sprint") == true, "Attack, Melee and Sprint stay claimed while carrying")
    check(host.jumps[#host.jumps] == false, "jumping stays taken while carrying")
    check(#host.errors == 0, "no VM error: " .. table.concat(host.errors, " | "))
end)

run("a carry kind claims Sprint by default, and a kind may opt out", function()
    local kind = M.normalizeCarryKind({ id = "crate", model = "crate.small", label = "Small crate" })
    check(type(kind) == "table" and type(kind.claims) == "table", "the minimal carry kind normalizes")
    if type(kind) == "table" and type(kind.claims) == "table" then
        check(kind.claims.sprint == true and kind.claims.walkSpeed == 1.2 and kind.claims.attack == true and
            kind.claims.jump == true, "default carry claims: walk 1.2 m/s, no jump, no fighting, no sprint")
    end
    local relaxed = M.normalizeCarryKind({ id = "light", model = "crate.cardboard", label = "Light crate",
        claims = { walkSpeed = 2.0, sprint = false } })
    check(type(relaxed) == "table" and relaxed.claims.sprint == false, "an explicit sprint = false is kept")
end)

-- ---------------------------------------------------------------------------
-- 12. `hideFor`: the listed players get no card and E does nothing for them;
--     everyone else is offered it as before (live 2026-10-13: a downed patient
--     saw the medic's "Stabilise the patient" card over her own body).
-- ---------------------------------------------------------------------------
run("hideFor hides the card from the listed players only", function()
    local hidden = newScene({ target = { hideFor = { 7 } }, localId = 7 })
    stand(hidden, 1.0, -30.0)
    hidden:run(1.5)
    local mine = hidden:invoke(hidden.vms.open77_actions, "open77_interactions", "all", table.pack())
    check(type(mine) == "table" and #mine == 0, "hideFor: no prompt for the listed player")
    local mark = #hidden.intents
    hidden:press("E", 0.3)
    check(#intentsSince(hidden, mark) == 0, "hideFor: E does nothing for the listed player")

    local other = newScene({ target = { hideFor = { 7 } }, localId = 8 })
    stand(other, 1.0, -30.0)
    other:run(1.5)
    mark = #other.intents
    other:press("E", 0.3)
    check(#intentsSince(other, mark) == 1, "hideFor: another player still fires")

    local refused = { { hideFor = "7" }, { hideFor = { 0 } }, { hideFor = { 1.5 } },
        { hideFor = { 1, 2, 3, 4, 5, 6, 7, 8, 9 } } }
    for _, extra in ipairs(refused) do
        local def = { id = "a", position = SPOT, actions = { "x" } }
        for k, v in pairs(extra) do def[k] = v end
        local target, reason = M.normalizeTarget(def)
        check(target == nil and reason == "invalid_target", "refused hideFor shape")
    end
    check(#hidden.errors == 0 and #other.errors == 0, "no VM error")
end)

-- 13. A carry kind without a binding gets its model's measured one: crate.ammo_box
--     (every RP job's crate) used the crate.small binding and floated in first person.
run("the default binding follows the carried model", function()
    local box = M.normalizeCarryKind({ id = "box", model = "crate.ammo_box", label = "Box" })
    local small = M.normalizeCarryKind({ id = "small", model = "crate.small", label = "Small" })
    local other = M.normalizeCarryKind({ id = "other", model = "crate.cargo", label = "Other" })
    check(box and box.binding.firstPerson.offset.z == -0.28 and box.binding.offset.y == -0.42,
        "crate.ammo_box: its own measured binding, both views")
    check(small and small.binding == M.DEFAULT_BINDING, "crate.small: the default binding")
    check(other and other.binding == M.DEFAULT_BINDING, "an unlisted model falls back to the default")
    local partial = M.normalizeCarryKind({ id = "p", model = "crate.ammo_box", label = "P",
        binding = { offset = { x = 0, y = -0.5, z = 0 } } })
    check(partial and partial.binding.offset.y == -0.5 and partial.binding.firstPerson.offset.y == -0.32,
        "a partial binding keeps the model's first-person placement")
end)

-- ---------------------------------------------------------------------------
-- 14. Carry items stacked on one point. Live 2026-10-13, two lab clients: two
--     nomad crates of different runs set down on the same loading point drew
--     NO "Pick up" card at all, from any distance or angle, while a lone crate
--     elsewhere drew its card and the server picked either one up from a lab
--     command; with one of the two gone, the other drew its card again.
--     The wire is server/carry.lua showTarget's, one target per item.
--
--     Before the stack rule this replay already drew the card and fired once,
--     with TWO prompts registered on the point: the coincident pair works in
--     the modelled host, so the live loss sits below what this host models
--     (client/main.lua, the note above `STACK_RADIUS`). What the client now
--     guarantees is that a stack is never two prompts on one point: ONE prompt
--     (the smallest item key) carries it, E sends exactly one intent, and the
--     next item takes the card when the first one leaves.
-- ---------------------------------------------------------------------------
local LOADING_POINT = { x = 1788.0, y = 2258.0, z = 180.3 }   -- rp_nomade loading point 2

local function crateWire(itemId, at, label)
    at = at or LOADING_POINT
    label = label or "Nomad crate"
    local target = assert(M.normalizeTarget({
        id = "item_" .. itemId, position = { x = at.x, y = at.y, z = at.z + 0.5 },
        bucket = 0, label = label, distance = 2.0, markerDistance = 10.0,
        marker = "diamond", requires = "empty",
        actions = { { action = "open77_actions:carry_pickup", label = "Pick up " .. label, key = "E" } },
    }))
    target.key = "item:" .. itemId     -- carry.lua: the internal key
    return {
        key = target.key, position = target.position, bucket = target.bucket,
        label = target.label, description = target.description, distance = target.distance,
        markerDistance = target.markerDistance, marker = target.marker, color = target.color,
        icon = target.icon, requires = target.requires, choices = target.actions,
        promptHeight = target.promptHeight, lookAt = target.lookAt, promptAt = target.promptAt,
        hideFor = target.hideFor,
    }
end

local function standNear(host, point, northOf, pitch)
    host.player = { x = point.x, y = point.y + northOf, z = point.z }
    host.camera.yaw, host.camera.pitch = 180.0, pitch
end

local function prompts(host)
    local mine = host:invoke(host.vms.open77_actions, "open77_interactions", "all", table.pack())
    return type(mine) == "table" and mine or {}
end

local function pickUp(host, where)
    local mark = #host.intents
    host:press("E", 0.3)
    local sent = intentsSince(host, mark)
    check(#sent == 1, where .. ": E sends exactly one intent, sent " .. #sent)
    check(sent[1] == nil or sent[1].action == "open77_actions:carry_pickup",
        where .. ": the intent is a pickup, got " .. tostring(sent[1] and sent[1].action))
    return sent[1] and sent[1].target
end

run("two items on the same point: one prompt, one card, E picks up exactly one", function()
    for _, view in ipairs({ { 1.2, -20.0 }, { 0.6, -10.0 }, { 4.0, -10.0 } }) do
        -- Listed out of key order: the carrier is the smallest key, not the first to arrive.
        local host = newScene({ targets = { crateWire("it-a1b2-2"), crateWire("it-a1b2-1") } })
        standNear(host, LOADING_POINT, view[1], view[2])
        host:run(1.5)
        local where = ("stacked, %.1f m, pitch %d"):format(view[1], view[2])
        check(#prompts(host) == 1, where .. ": the stack is one prompt, got " .. #prompts(host))
        local card = host:card()
        check(card ~= nil and card.label == "Pick up Nomad crate", where .. ": a card is drawn, got " ..
            tostring(card and card.label))
        if view[1] <= 1.5 then
            check(card ~= nil and card.color == BRIGHT, where .. ": in reach the card is active, got " ..
                tostring(card and card.color))
            local picked = pickUp(host, where)
            check(picked == "item:it-a1b2-1", where .. ": the smallest key carries the stack, got " ..
                tostring(picked))
        end
        check(#host.errors == 0, where .. ": no VM error: " .. table.concat(host.errors, " | "))
    end
end)

run("the next item of a stack takes the card when the first one leaves", function()
    local host = newScene({ targets = { crateWire("it-a1b2-1"), crateWire("it-a1b2-2") } })
    standNear(host, LOADING_POINT, 1.2, -20.0)
    host:run(1.5)
    check(pickUp(host, "first") == "item:it-a1b2-1", "the first E picks up the first item")
    -- The server took it: carry.lua hideTarget removes its target.
    host:toClient("open77:actions:targets", { generation = 1, upsert = {}, remove = { "item:it-a1b2-1" } })
    host:run(1.5)
    check(#prompts(host) == 1, "the second item has its prompt, got " .. #prompts(host))
    local card = host:card()
    check(card ~= nil and card.label == "Pick up Nomad crate" and card.color == BRIGHT,
        "the second item's card is drawn and live")
    check(pickUp(host, "second") == "item:it-a1b2-2", "the next E picks up the second item")
    -- A crate of another run set down on the stack later joins it: still one prompt, still a card.
    host:toClient("open77:actions:targets", { generation = 1, upsert = { crateWire("it-a1b2-0") }, remove = {} })
    host:run(1.5)
    check(#prompts(host) == 1, "a crate set down on the stack later joins it, got " .. #prompts(host))
    check(host:card() ~= nil, "and the card is still drawn")
    check(#host.errors == 0, "no VM error: " .. table.concat(host.errors, " | "))
end)

run("only a true stack is merged", function()
    -- A metre apart: a prompt each, as before.
    local apart = newScene({ targets = { crateWire("it-a1b2-1"),
        crateWire("it-a1b2-2", { x = LOADING_POINT.x + 1.0, y = LOADING_POINT.y, z = LOADING_POINT.z }) } })
    standNear(apart, LOADING_POINT, 1.2, -20.0)
    apart:run(1.5)
    check(#prompts(apart) == 2, "crates a metre apart keep a prompt each, got " .. #prompts(apart))
    check(apart:card() ~= nil, "apart: a card is drawn")
    -- The same point, not the same thing (the player can tell them apart): a prompt each.
    local mixed = newScene({ targets = { crateWire("it-a1b2-1"), crateWire("it-a1b2-2", nil, "Medical crate") } })
    standNear(mixed, LOADING_POINT, 1.2, -20.0)
    mixed:run(1.5)
    check(#prompts(mixed) == 2, "different items on one point keep a prompt each, got " .. #prompts(mixed))
    check(mixed:card() ~= nil, "mixed: a card is drawn")
    check(#apart.errors == 0 and #mixed.errors == 0, "no VM error")
end)

TestResult = { passed = passed, failed = #failures, failures = failures }
if not __open77_test_read then
    for _, failure in ipairs(failures) do print("FAIL " .. failure) end
    print(("[open77_actions prompt tests] %d passed, %d failed"):format(passed, #failures))
end
