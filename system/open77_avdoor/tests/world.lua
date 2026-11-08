-- =============================================================================
-- open77_avdoor -- tests/world.lua
-- =============================================================================
-- A simulated Open77 platform for the offline suites of open77_avdoor and
-- open77_avdrive: ONE server VM and one client VM per player, each a Lua
-- environment of its own (as each resource VM is on a real host), joined by a
-- fake network and a fake world -- players, vehicles, seats, doors, the
-- interactions service's cards, sounds, effects, fades and teleports.
--
-- The REAL resource files are loaded into those environments, so a suite
-- proves what the two halves say to each other, not only what each half does
-- alone. Time and the scheduler are driven by the suite (`W.advance`).
--
-- What is modelled is what the resources read and what was measured on the
-- XyberRP servers: the platform's own exit (the body dropped inside the hull,
-- then ejected 3.5 m behind and 2 m under it about 1.7 s later, for the pilot's
-- seat), `players.position` throwing on an id under 1, `setTransform` reading
-- an absent yaw as 0, and a frozen hull ignoring its owner's reports.
--
-- Nothing here is the platform. A suite that passes proves the bookkeeping and
-- the protocol between the halves; the in-game check is still needed.
-- =============================================================================

local W = {
    now = 1000000,      -- monotonic ms
    threads = {},       -- { co, wakeAt, vm }
    vms = {},           -- every VM, by name
    queue = {},         -- network messages and host events not yet delivered
    timers = {},        -- { at, fn }: the platform's own deferred work
    players = {},       -- [id] = player
    vehicles = {},      -- [id] = vehicle
    logs = {},          -- { vm, level, text }
    violations = {},    -- calls a real host would have thrown on
    threadErrors = {},
    sounds = {},        -- server effects.sound calls
    invoker = nil,      -- what GetInvokingResource answers
    resourceStates = {},
    groundAt = nil,     -- function(x, y) -> z|nil; nil is flat ground at 0
    -- Open terrain (the Badlands): function(x, y) -> z|nil. A Static ray --
    -- a client's `world.groundZ` -- does not meet it; a ray with the
    -- `Terrain` collision group does.
    terrainAt = nil,
    -- A client's `Open77.world.raycast`: nil (none), 'groups' (Stable 156:
    -- takes `groups`, Terrain among them, and refuses them beside `static` or
    -- `dynamic` with `collision_groups_conflict`), 'flags' (an older build:
    -- `groups` ignored, the ray meets Static and Dynamic -- the hulls).
    rays = nil,
    rayCount = 0,       -- rays a client cast down (groundZ and raycast)
    legacyExitCamera = nil, -- false: no client pulls its legacy exit camera after an AV exit
    boundsSpace = nil,  -- 'world': entityGeometry answers a world box (the card), else the hull's own (the client)
    observerDown = {},  -- [playerId] = true: that game never answers a ground query
    -- Custom locomotion (server `Open77.locomotion`): the styles some resource
    -- registered, each player's assignment `{ style, owner, revision }`, and
    -- every clip played `{ player, clip, options, at, owner }`. `nil` means
    -- the host has no locomotion API at all.
    locomotion = nil,
    visibility = {},    -- [playerId] = false while hidden from the others
    visibilityLog = {}, -- { player, visible, at }
}
Open77AvWorld = W

local function deepcopy(value, seen)
    if type(value) ~= 'table' then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local out = {}
    seen[value] = out
    for k, v in pairs(value) do out[deepcopy(k, seen)] = deepcopy(v, seen) end
    return out
end
W.copy = deepcopy

-- ── the ground ───────────────────────────────────────────────────────────────

function W.ground(x, y)
    if W.groundAt ~= nil then return W.groundAt(x, y) end
    return 0.0
end

-- ── the scheduler ────────────────────────────────────────────────────────────

-- THE HOST'S EXECUTION BUDGET (scripting/src/ResourceHost.cpp, `ResumeTask` and
-- `InstructionHook`): every resume of a task runs under a count hook that fires
-- every 10 000 VM instructions (`kInstructionHookStep`) and kills the resume
-- with "Open77 script execution budget exceeded" when the clock is past its
-- slice's deadline -- the frame budget (2 ms on a client) shared by the running
-- resources, never under 300 us (`kMinimumSlice`). On a loaded client the
-- slice is that floor and 10 000 instructions with natives take longer: a
-- resume that reaches the hook dies there (the laptop, 2026-10-28, 04:39:17 and
-- :23, twice in one exit). So here a resume dies at its 10 000th instruction of
-- resource code -- the simulated platform's own Lua (this file, the suite) is
-- not counted, as the host's natives run in C. A `pcall` in the resource
-- catches it, and the next 10 000 die again, as on the host.
-- `W.budget = nil` turns it off; `kill = false` only measures.
W.budget = { step = 250, limit = 10000, kill = true }
W.budgetKills = {}  -- { vm, count, where, trace }
W.budgetPeak = {}   -- [vm name] = { count, where }: the most one resume ran
W.budgetByOrigin = {} -- [thread origin] = { peak, where, resumes, over }: for a profile

local function resume(entry, ...)
    local vm = entry.vm
    local budget = W.budget
    local counted, nextKill, where = 0, budget ~= nil and budget.limit or nil, nil
    local mine = W.budgetHot ~= nil and {} or nil
    if budget ~= nil then
        debug.sethook(entry.co, function()
            local info = debug.getinfo(2, 'Sl')
            local source = info ~= nil and info.source or ''
            if source:find('/tests/', 1, true) ~= nil then return end
            counted = counted + budget.step
            where = (info.short_src or '?') .. ':' .. tostring(info.currentline or '?')
            -- A profile (`W.budgetHot`): each tick charged to every resource
            -- function on the stack (inclusive), and to the running one (self).
            if W.budgetHot ~= nil then
                local seen = {}
                for level = 2, 40 do
                    local frame = debug.getinfo(level, 'S')
                    if frame == nil then break end
                    local src = frame.source or ''
                    if src:sub(1, 1) == '@' and src:find('/tests/', 1, true) == nil then
                        local key = (frame.short_src or '?') .. ':' .. tostring(frame.linedefined)
                        if not seen[key] then
                            seen[key] = true
                            mine[key] = (mine[key] or 0) + budget.step
                            local row = W.budgetHot[key] or { incl = 0, self = 0 }
                            W.budgetHot[key] = row
                            row.incl = row.incl + budget.step
                            if level == 2 then row.self = row.self + budget.step end
                        end
                    end
                end
            end
            if counted >= nextKill then
                nextKill = nextKill + budget.limit
                W.budgetKills[#W.budgetKills + 1] = { vm = vm.name, count = counted, where = where,
                    trace = debug.traceback('', 2) }
                if budget.kill then error('Open77 script execution budget exceeded', 2) end
            end
        end, '', budget.step)
    end
    local ok, err = coroutine.resume(entry.co, ...)
    if budget ~= nil then
        if coroutine.status(entry.co) ~= 'dead' then debug.sethook(entry.co) end
        local peak = W.budgetPeak[vm.name]
        if peak == nil or counted > peak.count then W.budgetPeak[vm.name] = { count = counted, where = where } end
        local origin = entry.origin or '?'
        if mine ~= nil and counted >= 7000 then
            W.budgetHeavy = W.budgetHeavy or {}
            W.budgetHeavy[#W.budgetHeavy + 1] = { count = counted, origin = origin, fns = mine,
                case = W.caseName }
        end
        local row = W.budgetByOrigin[origin]
        if row == nil then row = { peak = 0, resumes = 0, over = 0 }; W.budgetByOrigin[origin] = row end
        row.resumes = row.resumes + 1
        if counted >= 6000 then row.over = row.over + 1 end
        if counted > row.peak then row.peak, row.where = counted, where end
    end
    if not ok then W.threadErrors[#W.threadErrors + 1] = vm.name .. ': ' .. tostring(err) end
end

local function originOf(fn)
    local info = debug.getinfo(fn, 'S')
    return info ~= nil and ((info.short_src or '?') .. ':' .. tostring(info.linedefined)) or '?'
end

local nextOrigin = nil
local function spawn(vm, fn, ...)
    local entry = { co = coroutine.create(fn), wakeAt = W.now, vm = vm, origin = nextOrigin or originOf(fn) }
    nextOrigin = nil
    W.threads[#W.threads + 1] = entry
    resume(entry, ...)
    return entry
end

local function currentEntry()
    local co = coroutine.running()
    for _, entry in ipairs(W.threads) do
        if entry.co == co then return entry end
    end
    return nil
end

--- Delivers what is queued: network messages and host events.
local function deliver()
    local guard = 0
    while #W.queue > 0 and guard < 1000 do
        guard = guard + 1
        local item = table.remove(W.queue, 1)
        item.run()
    end
end

function W.run()
    for _ = 1, 500 do
        deliver()
        local dueTimers = {}
        for _, timer in ipairs(W.timers) do if timer.at <= W.now then dueTimers[#dueTimers + 1] = timer end end
        if #dueTimers > 0 then
            local keep = {}
            for _, timer in ipairs(W.timers) do if timer.at > W.now then keep[#keep + 1] = timer end end
            W.timers = keep
            for _, timer in ipairs(dueTimers) do timer.fn() end
        end
        deliver()
        -- Every thread that is due runs once per pass; one that waits 0 is due
        -- again, so an awaited answer comes back within the same millisecond.
        local due = {}
        for _, entry in ipairs(W.threads) do
            if coroutine.status(entry.co) == 'suspended' and entry.wakeAt <= W.now and not entry.vm.dead then
                due[#due + 1] = entry
            end
        end
        for _, entry in ipairs(due) do
            if coroutine.status(entry.co) == 'suspended' and not entry.vm.dead then resume(entry) end
        end
        local live = {}
        for _, entry in ipairs(W.threads) do
            if coroutine.status(entry.co) ~= 'dead' and not entry.vm.dead then live[#live + 1] = entry end
        end
        W.threads = live
        if #due == 0 and #dueTimers == 0 and #W.queue == 0 then break end
    end
end

--- THE CLIP AS THE SCREENS DRAW IT: the platform's custom layer plays it only
--- on a body its game has on the ground (client/src/puppet/MirrorGraph.cpp),
--- so each clip playing is looked at as the clock moves -- how many looks found
--- its body off the ground (`air`), of how many (`looks`).
local function sampleClips()
    if W.locomotion == nil or W.locomotion.played == nil then return end
    for _, entry in ipairs(W.locomotion.played) do
        local spec = W.CLIPS ~= nil and W.CLIPS[entry.clip] or nil
        local player = W.players[entry.player]
        if spec ~= nil and player ~= nil and W.now >= entry.at and W.now < entry.at + spec.seconds * 1000.0
            and entry.sampledAt ~= W.now then
            entry.sampledAt = W.now
            entry.looks = (entry.looks or 0) + 1
            if not W.grounded(player) then
                entry.air = (entry.air or 0) + 1
                -- When a look first found it in the air (a boarding step's seat
                -- ends the clip's last 0.2 s in the seat, 1.7.0).
                entry.firstAirAt = entry.firstAirAt or W.now
            end
        end
    end
end

--- Whether a clip was drawn the whole time it was looked at (its body on the
--- ground at every look), or nil when it was never looked at.
function W.clipDrawn(entry)
    if entry == nil or (entry.looks or 0) == 0 then return nil end
    return (entry.air or 0) == 0
end

--- Moves the clock on by `ms`, waking every thread at its own time.
function W.advance(ms)
    local target = W.now + ms
    W.run()
    sampleClips()
    while W.now < target do
        local nextAt = target
        for _, entry in ipairs(W.threads) do
            if coroutine.status(entry.co) == 'suspended' and entry.wakeAt > W.now and entry.wakeAt < nextAt then
                nextAt = entry.wakeAt
            end
        end
        for _, timer in ipairs(W.timers) do
            if timer.at > W.now and timer.at < nextAt then nextAt = timer.at end
        end
        W.now = nextAt
        W.run()
        sampleClips()
    end
end

--- The platform's own deferred work, `ms` from now.
function W.after(ms, fn)
    W.timers[#W.timers + 1] = { at = W.now + ms, fn = fn }
end

-- ── the log ──────────────────────────────────────────────────────────────────

local function logger(vm)
    local function line(level)
        return function(...)
            local parts = {}
            for i = 1, select('#', ...) do parts[#parts + 1] = tostring((select(i, ...))) end
            W.logs[#W.logs + 1] = { vm = vm.name, level = level, text = table.concat(parts, '\t'), at = W.now }
        end
    end
    return { debug = line('debug'), info = line('info'), warn = line('warn'), error = line('error') }
end

--- The first log line of a VM (or any) matching a plain substring, or nil.
function W.logged(text, vmName, level)
    for _, entry in ipairs(W.logs) do
        if (vmName == nil or entry.vm == vmName) and (level == nil or entry.level == level)
            and entry.text:find(text, 1, true) ~= nil then
            return entry.text
        end
    end
    return nil
end

--- How many log lines match.
function W.count(text, vmName)
    local n = 0
    for _, entry in ipairs(W.logs) do
        if (vmName == nil or entry.vm == vmName) and entry.text:find(text, 1, true) ~= nil then n = n + 1 end
    end
    return n
end

--- Every error or warning a VM logged, for a suite that wants none.
function W.problems(vmName)
    local out = {}
    for _, entry in ipairs(W.logs) do
        if (vmName == nil or entry.vm == vmName) and entry.level == 'error' then out[#out + 1] = entry.text end
    end
    return out
end

-- ── the world: players and vehicles ──────────────────────────────────────────

--- A player, standing at a point. Their game reports `locale`.
function W.player(id, x, y, z, options)
    options = options or {}
    local player = {
        id = id, x = x, y = y, z = z or 0.0, yaw = options.yaw or 0.0, bucket = options.bucket or 0,
        dead = false, seat = nil, waypoint = nil, waypointBroken = false,
        locale = options.locale or { code = 'en-US', gameLanguage = 'en-us', voiceLanguage = 'en-us' },
        notices = {}, fades = {}, teleports = {}, keys = {}, sfx = {}, vfx = {}, vfxLog = {}, audio = {}, cards = {},
        nextHandle = 1, views = {}, frozenLog = {}, noPerspective = options.noPerspective,
        -- The perspective arbiter: how long a forced third person takes to
        -- dress the stand-in once nothing blocks it (`false`: never ready), and
        -- the client's legacy exit camera (`cameraLog`: its switches).
        tpsReadyMs = options.tpsReadyMs, legacyCamera = false, cameraLog = {},
        -- THE ARBITER AS STABLE 157 HAS IT (1.7.5), when `arbiter = 'stable157'`
        -- (W.realArbiter below): the stand-in made once a session
        -- (`proxyBuildMs` from the first third person asked, then kept parked),
        -- `holding_current` while it is built behind first person, the
        -- platform's own 3 s timeout and 3 s cooldown, the animated reveal
        -- (`revealMs`), and a request let go before the body is ready changing
        -- nothing on screen -- unless `noSoftCancel` (an older client: every
        -- switch is played out once asked).
        arbiter = options.arbiter, proxyBuildMs = options.proxyBuildMs, revealMs = options.revealMs,
        noSoftCancel = options.noSoftCancel, arbLog = {},
        -- The game's frame time: the arbiter counts frames (16 ms when unset).
        -- When set, this player's client VM also runs its threads on frames:
        -- a `Wait` ends on the first frame after it (the host's ticks).
        frameMs = options.frameMs, orbitLog = {}, noCameraView = options.noCameraView,
        -- What this player's game draws of the OTHER players' exits: its own
        -- remote dismount holds a body that left its seat in the seat for
        -- `dismountMs` (0: let go at once; the laptop, 2026-10-28: 2811 ms).
        dismountMs = options.dismountMs, dismountUntil = {},
        -- THE BODY'S HEADING (1.5.0). Something that turns the body after the
        -- exit placed it: `turnOnChaseRelease` degrees as the client's chase
        -- camera lets go (the laptop, 2026-10-28, 03:15:44: planned 75, drawn
        -- 245.8), `orbitTurnsBody` (a camera swing that turns the body with
        -- it), `stickyYaw = { yaw, times }` (turned back to that heading 50 ms
        -- after each of the next `times` placements).
        turnOnChaseRelease = options.turnOnChaseRelease, orbitTurnsBody = options.orbitTurnsBody,
        stickyYaw = options.stickyYaw,
        -- THE PLATFORM'S OWN EXIT (`exitAirMs`): how long after the seat empties
        -- its game still says the body is off the ground whatever is done to it
        -- (0 by default: not measured without a fade on; 1.6.0 tests both).
        exitAirMs = options.exitAirMs,
        -- ON THE GROUND: a body put over the ground lands `LAND_MS` later --
        -- unless held still with `hoverWhenFrozen` (it stays in the air until
        -- its place is let go) or `hoverUntil` (in the air whatever is done) --
        -- or THE NATIVE FADE is out (`W.screenHeld`, measured: it holds the body
        -- still wherever it is, `screenAir` for one moved under it, until the
        -- fade-in has run; `fadeHoldsBody = false` for a game where it does not).
        hoverWhenFrozen = options.hoverWhenFrozen, landAt = nil, hovering = false, hoverUntil = nil,
        fadeHoldsBody = options.fadeHoldsBody ~= false, screenAir = nil, screenThawAt = nil,
        -- What another game draws of this body: `drawnFor[viewerId] = { yaw,
        -- grounded, weapon, ageMs, noClip }` (a heading, a body in the air, a
        -- weapon, stale movement, a clip not drawn there).
        drawnFor = {},
        -- Before `netReadyAt` this player's client cannot send (the game still
        -- loading): `TriggerServerEvent` answers false, network_unavailable.
        netReadyAt = options.netReadyAt,
    }
    W.players[id] = player
    return player
end

--- How long a body put over the ground takes to land on it.
W.LAND_MS = 80

--- Whether the native fade holds this player's body still now: from the
--- fade-out until its fade-in has run (`screenThawAt`). Measured on the laptop
--- (Staging, 2026-10-28, 10:32:56 and 01:54:15/32): a body put beside the AV
--- 3 cm over the ground under the exit's cut to black hung there, "off the
--- ground (falling)", 0.00 m/s, for the whole fade, held or not, put 5 cm over
--- the ground again or not, and moved the moment the fade-in had run (the
--- client's `vflt-exit-tpp-off`, body faster than 0.4 m/s, each time at fade
--- over + `IN_MS`); the platform's notes say the same of every vehicle (the
--- fade's byte is world-update flag 0x8, in the 0x1B physics block).
function W.screenHeld(player)
    if not player.fadeHoldsBody then return false end
    if player.covered ~= nil then return true end
    return player.screenThawAt ~= nil and W.now < player.screenThawAt
end

--- The fade's hold let go (its fade-in has run): a body moved under it lands.
function W.screenThaw(player)
    if W.screenHeld(player) then return end
    player.screenThawAt = nil
    if player.screenAir then
        player.screenAir = nil
        player.screenLandings = (player.screenLandings or 0) + 1
        if not player.frozenPosition then
            player.hovering, player.landAt = false, W.now + W.LAND_MS
            W.landLater(player)
        else
            -- Held by the forced freeze meanwhile: in the air until let go.
            player.frozenAir = true
        end
    end
end

--- The body comes down on the ground `LAND_MS` from now (its height the
--- ground's), unless it was put somewhere else or held in the air meanwhile.
function W.landLater(player)
    local due = player.landAt
    W.after(W.LAND_MS, function()
        if player.landAt ~= due or player.hovering then return end
        if player.hoverUntil ~= nil and W.now < player.hoverUntil then return end
        -- The native fade holds it where it is.
        if W.screenHeld(player) then return end
        local ground = W.ground(player.x, player.y)
        if ground ~= nil and player.z > ground then player.z = ground end
    end)
end

--- Whether a body stands on the ground, as its own game has it (the player
--- state machine's `IsOnGround`, client/src/api/Movement.cpp).
--
-- WHAT WAS MEASURED (1.6.0): the native fade holds the body still wherever it
-- is (`W.screenHeld`): a body moved under it is off the ground ("falling") until
-- the fade-in has run, then lands `LAND_MS` later; one standing when the fade
-- came stays standing. A seated body is not on the ground. A body the
-- platform's forced freeze (`freezePosition`) takes while it is off the ground
-- -- or that is moved while that freeze holds it -- stays off it until the
-- freeze lets go (`frozenAir`; conservative: the exit never does either). A
-- move of a free body loses the ground for `LAND_MS`. The engine's NoMovement
-- restriction (`character.setFrozen`) changes nothing of it. `exitAirMs`: a
-- platform whose own exit keeps the body off the ground that long after the
-- seat empties (not measured; 1.6.0 tests it).
function W.grounded(player)
    if player.seat ~= nil then return false end
    if player.exitingUntil ~= nil and W.now < player.exitingUntil then return false end
    if player.screenAir then return false end
    if player.frozenAir then return false end
    if player.hoverUntil ~= nil and W.now < player.hoverUntil then return false end
    if player.hovering then return false end
    return player.landAt == nil or W.now >= player.landAt
end

--- The body was moved (a teleport, the platform's eject): under the native
--- fade it hangs where it is put until the fade-in has run; held by the forced
--- freeze it is left off the ground; free, it lands `LAND_MS` later.
function W.moved(player)
    if W.screenHeld(player) then
        player.screenAir = true
        player.screenMoves = (player.screenMoves or 0) + 1
        player.hovering, player.landAt = false, nil
        if player.frozenPosition then player.frozenAir = true end
        return
    end
    if player.frozenPosition then
        player.frozenAir = true
        player.hovering, player.landAt = false, nil
        return
    end
    player.hovering, player.landAt = false, W.now + W.LAND_MS
    W.landLater(player)
end

--- A player's body as another game draws it: its client-side entity id.
W.PLAYER_ENTITY = 700000

--- An aircraft (or any vehicle), parked at a point.
function W.vehicle(id, record, x, y, z, options)
    options = options or {}
    local vehicle = {
        id = id, record = record, x = x, y = y, z = z or 1.5, heading = options.heading or 0.0,
        bucket = options.bucket or 0, speed = options.speed or 0.0, seats = {}, exiting = {},
        locked = options.locked == true, lockedFor = {}, frozen = false, doors = {}, destroyed = false,
        physicsOwner = 0, epoch = 1, engineOn = options.engineOn == true, revision = 1,
        drawnOffset = nil, transforms = {}, frozenLog = {},
        halfWidth = options.halfWidth, halfLength = options.halfLength,
    }
    W.vehicles[id] = vehicle
    return vehicle
end

local SEAT_OFFSET = {
    seat_front_left = { side = 1, along = 1.5 },
    seat_front_right = { side = -1, along = 1.5 },
    seat_back_left = { side = 1, along = -0.5 },
    seat_back_right = { side = -1, along = -0.5 },
}

--- The Rayfield Excalibur's door slots (`vehicle_slots`), in its own frame
--- (+x right, +y ahead): all on its left, x -0.95 to -1.14 (the game's files).
W.EXCALIBUR_SLOTS = {
    door_a_01 = { x = -1.10, y = 0.35, z = -0.10 },
    door_b_01 = { x = -1.05, y = -0.15, z = -0.25 },
    door_c_01 = { x = -1.00, y = -0.60, z = -0.40 },
    door_hinge_a_01 = { x = -0.95, y = 1.02, z = 0.20 },
    door_hinge_b_01 = { x = -0.95, y = -1.33, z = 0.20 },
}

--- A body's hips over its feet's point when it stands.
W.HIPS_HEIGHT = 0.95

--- The vehicle's forward and left on the ground.
local function axes(vehicle)
    local r = math.rad(vehicle.heading)
    -- REDengine: yaw 0 faces +y and grows toward -x.
    local fx, fy = -math.sin(r), math.cos(r)
    return fx, fy, -fy, fx
end
W.axes = axes

--- Where a seated body is: in the cockpit, a metre up.
local function seatPoint(vehicle, seat)
    local fx, fy, lx, ly = axes(vehicle)
    local spec = SEAT_OFFSET[seat] or { side = 0, along = 0 }
    return vehicle.x + lx * 0.8 * spec.side + fx * spec.along,
        vehicle.y + ly * 0.8 * spec.side + fy * spec.along, vehicle.z + 1.0
end

local function key(id)
    if type(id) == 'number' then
        if id == math.floor(id) then return ('%d'):format(id) end
        return tostring(id)
    end
    return tostring(id)
end

--- The vehicle a host read names: an integer, a whole float or a decimal string.
function W.find(id)
    if id == nil then return nil end
    local number = tonumber(id)
    if number == nil then return nil end
    for vid, vehicle in pairs(W.vehicles) do
        if key(vid) == key(number) then return vehicle end
    end
    return nil
end

local function occupantsOf(vehicle)
    local out = {}
    for seat, playerId in pairs(vehicle.seats) do
        out[#out + 1] = { playerId = playerId, seat = seat, exiting = vehicle.exiting[seat] == true }
    end
    table.sort(out, function(a, b) return a.seat < b.seat end)
    return out
end

--- Raises a host event on every server VM, the id as text (as hosts do).
function W.hostEvent(name, ...)
    local args = table.pack(...)
    for _, vm in pairs(W.vms) do
        if vm.side == 'server' and not vm.dead then
            W.queue[#W.queue + 1] = { run = function() vm.fire(name, table.unpack(args, 1, args.n)) end }
        end
    end
end

--- Raises a local event on every client VM (the client host's own events).
function W.clientEvent(name, ...)
    local args = table.pack(...)
    for _, vm in pairs(W.vms) do
        if vm.side == 'client' and not vm.dead then
            W.queue[#W.queue + 1] = { run = function() vm.fire(name, table.unpack(args, 1, args.n)) end }
        end
    end
end

local function occupancyChanged(vehicle)
    vehicle.revision = vehicle.revision + 1
    W.hostEvent('onVehicleOccupancyChanged', key(vehicle.id), vehicle.revision)
end

--- THE GAME'S OWN ENTRY (1.7.4): F on a door's mount choice. The platform
--- offers none on a vehicle locked for that player (its per-player view), and
--- checks again at the mounting boundary; otherwise the body is mounted at once,
--- with no step. @return boolean mounted, string|nil why not
function W.gameEntry(playerId, vehicleId, seat)
    local player, vehicle = W.players[playerId], W.find(vehicleId)
    if player == nil or vehicle == nil then return false, 'nothing there' end
    local exception = vehicle.lockedFor[playerId]
    local locked = exception
    if locked == nil then locked = vehicle.locked == true end
    W.gameEntries = W.gameEntries or {}
    W.gameEntries[#W.gameEntries + 1] = { player = playerId, id = vehicle.id, seat = seat, locked = locked, at = W.now }
    if locked then return false, 'no mount choice (locked for this player)' end
    if vehicle.seats[seat] ~= nil then return false, 'seat taken' end
    W.seat(playerId, vehicleId, seat)
    return true
end

--- Seats a player directly (the platform's mount, for a suite's setup).
function W.seat(playerId, vehicleId, seat)
    local player, vehicle = W.players[playerId], W.find(vehicleId)
    vehicle.seats[seat] = playerId
    player.seat = { vehicleId = vehicle.id, seat = seat }
    player.x, player.y, player.z = seatPoint(vehicle, seat)
    if seat == 'seat_front_left' then
        vehicle.physicsOwner = playerId
        vehicle.epoch = vehicle.epoch + 1
    end
    occupancyChanged(vehicle)
end

--- The first-person camera attached while the arbiter holds a forced third
--- person (`SetThirdPerson(false)`: the client's own exit camera off, or a
--- resource's `camera.thirdPerson(false)`): a camera the decision did not
--- make, the fatal row for 1.5 s, then third person prepared again (Staging,
--- 2026-10-27, 17:39:21.97 to 17:39:23.64).
function W.attachFirstPerson(player)
    if player.lockedView ~= 'tps' then return end
    player.attachUntil = W.now + 1500
    player.tpsFrom = nil
    player.attaches = (player.attaches or 0) + 1
end

--- A player's frame time, in ms.
function W.frameOf(player)
    return player.frameMs or 16
end

--- The perspective arbiter's frames: twelve clean ones release its fatal row
--- (`exitFrames`, PerspectiveArbiter.hpp); a forced third person then commits
--- in two, reveals the first-person body for two and the stand-in for two more
--- before it settles -- or `tpsReadyMs` after it began, when that is later
--- (the stand-in dressing).
W.FATAL_EXIT_FRAMES = 12

-- ── the arbiter as Stable 157 has it (1.7.5) ─────────────────────────────────
-- client/src/api/PerspectiveArbiter.cpp and SelfView.cpp, as far as a resource
-- sees them through `Open77.perspective.state()`:
--   * a request for third person begins a transition: `preparing` one frame
--     (the stand-in's spawn let go of its park for one step), then
--     `holding_current` -- first person still on screen -- until the stand-in
--     is built (`proxyBuildMs` after the session's FIRST request; once built it
--     stays, parked, and a later request finds it ready);
--   * built: `committing` one frame, `revealing` (the camera pulls out; the
--     first-person body one frame, then the stand-in) for `revealMs`, then
--     settled in third person with `body = proxy`;
--   * `preparing`/`holding_current` past 3 s (`prepareTimeoutSeconds`): first
--     person restored, `prepare_timeout`, and no new try for 3 s
--     (`retryCooldown`); the stand-in goes on being built meanwhile;
--   * the request let go while `preparing`/`holding_current`: first person,
--     nothing shown, the stand-in still built (Stable 157's "key pressed twice
--     before the stand-in was ready"); `noSoftCancel`: the switch is played out
--     to third person, then back;
--   * let go while revealing or in third person: `concealing` (the camera
--     comes back in, still third person) for `revealMs`, then first person;
--   * a seat, or the exit's foreign cameras (the fatal row), take the view
--     before anything else and end a transition in flight.
W.PREPARE_TIMEOUT_MS = 3000
W.RETRY_COOLDOWN_MS = 3000

local function arbNote(player, a, now)
    local line = ('%s/%s/%s/%s'):format(a.mode, a.transition, a.reason, a.body)
    if a.lastLine ~= line then
        a.lastLine = line
        player.arbLog[#player.arbLog + 1] = { at = now, mode = a.mode, transition = a.transition, reason = a.reason,
            body = a.body }
    end
end

local function arbSet(a, mode, transition, reason, body, now)
    a.mode, a.transition, a.reason, a.body = mode, transition, reason, body
    a.since = now
end

local function proxyReady(player, now)
    return player.proxy ~= nil and now >= player.proxy.readyAt
end

--- One frame of the arbiter at `now`, given the world rows read by the caller.
local function arbFrame(player, a, now, row)
    local frame = W.frameOf(player)
    local want = player.lockedView == 'tps' and 'tps' or 'fpp'
    if row ~= nil then
        -- A world row (a seat, the fatal row): it takes the view at once.
        a.flow = nil
        arbSet(a, 'fpp', 'settled', row.reason, row.body, now)
        a.committed = 'fpp'
        return
    end
    if a.flow == nil then
        if a.committed == 'tps' then
            if want == 'tps' then
                if a.reason ~= 'resource_forced' or a.transition ~= 'settled' then
                    arbSet(a, 'tps', 'settled', 'resource_forced', 'proxy', now)
                end
            else
                a.flow = { kind = 'conceal', at = now }
                arbSet(a, 'tps', 'concealing', 'player_preference', 'proxy', now)
            end
            return
        end
        -- First person, settled.
        if want == 'tps' and (a.cooldownUntil == nil or now >= a.cooldownUntil) then
            a.flow = { kind = 'reveal', at = now, step = 'preparing' }
            if player.proxy == nil then
                player.proxy = { since = now, readyAt = now + (player.proxyBuildMs or 2800) }
                player.proxySpawns = (player.proxySpawns or 0) + 1
            end
            arbSet(a, 'fpp', 'preparing', a.cooldownUntil ~= nil and 'prepare_timeout' or 'resource_forced',
                'player_body', now)
            a.cooldownUntil = nil
            return
        end
        if want == 'fpp' and a.reason ~= 'prepare_timeout' and (a.reason ~= 'player_preference' or a.transition ~= 'settled') then
            arbSet(a, 'fpp', 'settled', 'player_preference', 'player_body', now)
        end
        if want == 'fpp' and a.reason == 'prepare_timeout' and a.cooldownUntil ~= nil and now >= a.cooldownUntil then
            a.cooldownUntil = nil
            arbSet(a, 'fpp', 'settled', 'player_preference', 'player_body', now)
        end
        return
    end
    local flow = a.flow
    if flow.kind == 'reveal' then
        if flow.step == 'preparing' or flow.step == 'holding' then
            if want ~= 'tps' then
                if not player.noSoftCancel then
                    -- Let go before the body was ready: nothing shown, the
                    -- stand-in still built, parked.
                    a.flow = nil
                    a.committed = 'fpp'
                    player.softCancels = (player.softCancels or 0) + 1
                    arbSet(a, 'fpp', 'settled', 'player_preference', 'player_body', now)
                    return
                end
                flow.latched = true
            end
            if now - flow.at > W.PREPARE_TIMEOUT_MS then
                a.flow = nil
                a.committed = 'fpp'
                a.cooldownUntil = now + W.RETRY_COOLDOWN_MS
                player.prepareTimeouts = (player.prepareTimeouts or 0) + 1
                arbSet(a, 'fpp', 'settled', 'prepare_timeout', 'player_body', now)
                return
            end
            if proxyReady(player, now) then
                flow.step = 'committing'
                arbSet(a, 'fpp', 'committing', a.reason, 'player_body', now)
                return
            end
            if flow.step == 'preparing' then
                flow.step = 'holding'
                arbSet(a, 'fpp', 'holding_current', a.reason, 'player_body', now)
            end
            return
        end
        if flow.step == 'committing' then
            flow.step = 'revealing'
            flow.revealAt = now
            arbSet(a, 'tps', 'revealing', 'resource_forced', 'player_body', now)
            return
        end
        if flow.step == 'revealing' then
            if want ~= 'tps' and not flow.latched then
                a.flow = { kind = 'conceal', at = now }
                arbSet(a, 'tps', 'concealing', 'player_preference', 'proxy', now)
                return
            end
            if a.body ~= 'proxy' then a.body = 'proxy' end
            if now - flow.revealAt >= math.max(player.revealMs or 300, 2 * frame) then
                a.flow = nil
                a.committed = 'tps'
                arbSet(a, 'tps', 'settled', 'resource_forced', 'proxy', now)
                if flow.latched then
                    -- An older client: played out, then back.
                    a.flow = { kind = 'conceal', at = now }
                    arbSet(a, 'tps', 'concealing', 'player_preference', 'proxy', now)
                end
            end
            return
        end
    elseif flow.kind == 'conceal' then
        if now - flow.at >= math.max(player.revealMs or 300, 2 * frame) then
            a.flow = nil
            a.committed = 'fpp'
            arbSet(a, 'fpp', 'settled', 'player_preference', 'player_body', now)
        end
    end
end

--- The world rows the real model obeys before any request, as the simple one
--- does: a seat (the engine's view), then the exit's foreign cameras and the
--- twelve clean frames after them (the fatal row).
function W.arbiterRow(player)
    return function(at)
        if player.seat ~= nil and player.chaseCamera ~= true then return { reason = 'vehicle', body = 'native' } end
        if player.legacyCamera or player.chaseCamera
            or (player.attachUntil ~= nil and at < player.attachUntil and player.lockedView == 'tps') then
            return { reason = 'fatal_state', body = 'player_body' }
        end
        local clean = player.unblockedAt
        if player.attachUntil ~= nil and player.lockedView == 'tps' then
            clean = math.max(clean or player.attachUntil, player.attachUntil)
        end
        if clean ~= nil and at < clean + W.FATAL_EXIT_FRAMES * W.frameOf(player) then
            return { reason = 'fatal_state', body = 'player_body' }
        end
        return nil
    end
end

--- The arbiter brought up to `now`, a frame at a time.
-- @param row function|nil the world rows at a time: `{ reason, body }` or nil
function W.arbiterAt(player, now, row)
    local a = player.arb
    if a == nil then
        a = { mode = 'fpp', transition = 'settled', reason = 'player_preference', body = 'player_body',
            committed = 'fpp', since = now, frameAt = now }
        player.arb = a
        arbNote(player, a, now)
    end
    local frame = W.frameOf(player)
    local steps = 0
    while a.frameAt + frame <= now and steps < 20000 do
        a.frameAt = a.frameAt + frame
        steps = steps + 1
        arbFrame(player, a, a.frameAt, row ~= nil and row(a.frameAt) or nil)
        arbNote(player, a, a.frameAt)
    end
    if steps >= 20000 then a.frameAt = now end
    return a
end

--- A player steps out of their seat the way the platform does it: the seat is
--- flagged as leaving, then emptied; the body is dropped at the cockpit's exit
--- point INSIDE the hull; for the pilot's seat, about 1.7 s later the
--- platform's deferred eject puts it 3.5 m behind and 2 m under the hull's
--- centre (measured on XyberRP, 2026-09-29).
--- `confirmMs` (100): how long the server holds the seat, flagged as leaving,
--- before the leaving game's confirmation frees it (`VehicleSeatAction.Exit`).
function W.leave(playerId, options)
    options = options or {}
    local player = W.players[playerId]
    local seat = player.seat
    if seat == nil then return end
    local vehicle = W.find(seat.vehicleId)
    vehicle.exiting[seat.seat] = true
    player.lastHull = vehicle.id
    -- THE GAME'S OWN EXIT, ANIMATED (`animatedMs`, the Militech Manticore's: a
    -- car's exit, 2.1 s on Staging, 2026-10-30): the engine holds the body
    -- mounted in the exit's workspot that long, and a move does not hold.
    -- `forced`: the platform's forced exit, which the leaving game makes instant.
    player.animatedUntil = (options.animatedMs or 0) > 0 and (W.now + options.animatedMs) or nil
    -- `mountUnreadMs`: the engine's mount not said for that long (the snapshot
    -- without its `vehicle`, as the Excalibur's exit read on Staging).
    player.mountUnreadUntil = (options.mountUnreadMs or 0) > 0 and (W.now + options.mountUnreadMs) or nil
    player.lastLeave = { forced = options.forced == true, animatedMs = options.animatedMs, at = W.now }
    -- Off the ground, whatever is done, for `exitAirMs` after the seat empties
    -- (`options.exitMs` for this exit): a platform whose own exit holds the body
    -- that long (not measured; 0 by default).
    local airMs = options.exitMs or player.exitAirMs or 0
    player.exitingUntil = airMs > 0 and (W.now + airMs) or nil
    -- THE EXIT'S DRAG (measured on Staging, 2026-10-28, 13:20:09 and 13:20:43,
    -- 2.50.0+op77.156): the exit un-masks the hull on the leaving game, whose
    -- engine draws it at the pad its chassis still holds (`vehicle.padFor
    -- [playerId]`, where its first flight on that game began) until the
    -- platform re-masks it (`dragMs`, 190 ms: a 150 ms grace and the next
    -- frame; 0: gone by between two frames) -- and the leaving body goes with
    -- it: dropped beside the dragged hull, where the re-mask does not fetch it
    -- from. A game simulating the hull may send that pose as the hull's own
    -- (`vehicle.dragTaken`): the server takes it (its first sample since the
    -- grant, VehicleAuthorityService `avMaximum`) and refuses the real one after
    -- -- the hull revoked, its canonical on the pad, the leaving game drawing its
    -- re-masked hull where it really stood until its replication converges.
    local pad = vehicle.padFor ~= nil and vehicle.padFor[playerId] or nil
    local dropAt = nil
    if pad ~= nil and math.sqrt((pad.x - vehicle.x) ^ 2 + (pad.y - vehicle.y) ^ 2) > 0.5 then
        local dx, dy = pad.x - vehicle.x, pad.y - vehicle.y
        local dragMs = options.dragMs or vehicle.dragMs or 190
        local token = {}
        vehicle.drawnOffsetFor = vehicle.drawnOffsetFor or {}
        if dragMs > 0 then
            local offset = { x = dx, y = dy, z = 0, token = token }
            vehicle.drawnOffsetFor[playerId] = offset
            W.after(dragMs, function()
                if vehicle.drawnOffsetFor ~= nil and vehicle.drawnOffsetFor[playerId] == offset then
                    vehicle.drawnOffsetFor[playerId] = nil
                end
            end)
            -- `netDrag`: that game's own newest sample of the hull is the dragged
            -- pose too, while it lasts (Staging, 13:21:39: the engine's frame and
            -- the network's both on the pad at the exit's first look).
            if options.netDrag then
                vehicle.netOffsetFor = vehicle.netOffsetFor or {}
                local net = { x = dx, y = dy, z = 0 }
                vehicle.netOffsetFor[playerId] = net
                W.after(dragMs, function()
                    if vehicle.netOffsetFor ~= nil and vehicle.netOffsetFor[playerId] == net then
                        vehicle.netOffsetFor[playerId] = nil
                    end
                end)
            end
        end
        dropAt = { x = vehicle.x + dx, y = vehicle.y + dy }
        -- Dropped beside the dragged hull on the exit's own frame (the laptop's
        -- log: the body already off the seat there when the exit was seen);
        -- `dragDropLate`: the drop at the seat's release instead, after the
        -- exit's first moves.
        if options.dragDropLate then
            player.x, player.y = player.x + dx, player.y + dy
        else
            local _, _, lx, ly = axes(vehicle)
            local spec = SEAT_OFFSET[seat.seat] or { side = 1 }
            player.x, player.y, player.z = dropAt.x + lx * 1.2 * spec.side, dropAt.y + ly * 1.2 * spec.side, vehicle.z
            dropAt.done = true
        end
        player.dragged = { x = dx, y = dy, at = W.now }
        if vehicle.dragTaken and vehicle.physicsOwner == playerId then
            W.after(options.dragTakenMs or 30, function()
                local realX, realY = vehicle.x, vehicle.y
                vehicle.x, vehicle.y = pad.x, pad.y
                vehicle.physicsOwner = 0
                vehicle.epoch = vehicle.epoch + 1
                vehicle.dragTakenAt = W.now
                vehicle.drawnOffsetFor = vehicle.drawnOffsetFor or {}
                local offset = { x = realX - pad.x, y = realY - pad.y, z = 0 }
                vehicle.drawnOffsetFor[playerId] = offset
                W.after(1700, function()
                    if vehicle.drawnOffsetFor ~= nil and vehicle.drawnOffsetFor[playerId] == offset then
                        vehicle.drawnOffsetFor[playerId] = nil
                    end
                end)
            end)
        end
    end
    occupancyChanged(vehicle)
    W.after(options.confirmMs or 100, function()
        vehicle.seats[seat.seat] = nil
        vehicle.exiting[seat.seat] = nil
        player.seat = nil
        if vehicle.physicsOwner == playerId then vehicle.physicsOwner = 0 end
        -- EVERY OTHER GAME's own dismount of this body begins now, and holds it
        -- in its seat there for that game's `dismountMs`
        -- (PlayerReplication.cpp, `BeginDismountPresentation`).
        for otherId, other in pairs(W.players) do
            if otherId ~= playerId and (other.dismountMs or 0) > 0 then
                player.dismountUntil[otherId] = W.now + other.dismountMs
            end
        end
        local fx, fy, lx, ly = axes(vehicle)
        local spec = SEAT_OFFSET[seat.seat] or { side = 1 }
        -- Beside the hull -- the dragged one, when the exit dragged it (and did
        -- not drop the body there on its own frame already).
        if dropAt == nil or not dropAt.done then
            local ox, oy = dropAt ~= nil and dropAt.x or vehicle.x, dropAt ~= nil and dropAt.y or vehicle.y
            player.x, player.y, player.z = ox + lx * 1.2 * spec.side, oy + ly * 1.2 * spec.side, vehicle.z
        end
        occupancyChanged(vehicle)
    end)
    -- THE CLIENT'S LEGACY EXIT CAMERA: 1.5 s after an AV exit the client pulls
    -- the camera behind the first-person body (VehicleReplication.cpp,
    -- `vflt-exit-tpp-on`); the perspective arbiter reads it as a foreign camera.
    -- Until then its chase camera still holds the screen (detached as well).
    if type(vehicle.record) == 'string' and vehicle.record:lower():find('^vehicle%.av_') and W.legacyExitCamera ~= false then
        player.chaseCamera = true
        -- The client's exit code runs on its next tick, a frame after the seat
        -- emptied, and its deadline is looked at once a frame.
        W.after(100 + 1500 + W.frameOf(player), function()
            player.chaseCamera = false
            if player.seat ~= nil then return end
            -- THE CHASE CAMERA LETS GO: it puts the player's camera back where
            -- the seat held it, and the body turns to that view
            -- (`turnOnChaseRelease`).
            if player.turnOnChaseRelease ~= nil then
                player.yaw = ((player.yaw or 0) + player.turnOnChaseRelease) % 360.0
                player.turnLog = player.turnLog or {}
                player.turnLog[#player.turnLog + 1] = { why = 'chase', yaw = player.yaw, at = W.now }
            end
            player.legacyCamera = true
            player.cameraLog[#player.cameraLog + 1] = { legacy = true, on = true, at = W.now }
            -- `vflt-exit-tpp-off`: the client turns that camera off again on
            -- the body's first move faster than 0.4 m/s, 1.2 s or more after it
            -- came -- through `Api::Camera::SetThirdPerson(false)` (the body
            -- hidden, the first-person camera attached), whoever turned the
            -- camera off since (Staging, 2026-10-27, 17:39:21.449).
            local engagedAt, last, lastAt = W.now, { x = player.x, y = player.y, z = player.z }, W.now
            local function watch()
                if player.exitTppOff ~= nil or player.seat ~= nil then return end
                local now = W.now
                local moved = math.sqrt((player.x - last.x) ^ 2 + (player.y - last.y) ^ 2 + (player.z - last.z) ^ 2)
                local speed = moved / math.max(0.001, (now - lastAt) / 1000.0)
                last, lastAt = { x = player.x, y = player.y, z = player.z }, now
                if now - engagedAt >= 1200 and speed > 0.4 then
                    player.exitTppOff = now
                    if player.legacyCamera then player.unblockedAt = now end
                    player.legacyCamera = false
                    player.cameraLog[#player.cameraLog + 1] = { legacy = true, on = false, client = true, at = now }
                    W.attachFirstPerson(player)
                    return
                end
                W.after(100, watch)
            end
            W.after(100, watch)
        end)
    end
    if seat.seat == 'seat_front_left' and options.eject ~= false then
        W.after(100 + 1700, function()
            if player.seat ~= nil then return end
            local fx, fy = axes(vehicle)
            player.x, player.y, player.z = vehicle.x - fx * 3.5, vehicle.y - fy * 3.5, vehicle.z - 2.0
            player.ejected = (player.ejected or 0) + 1
            W.moved(player)
        end)
    end
end

-- ── the network ──────────────────────────────────────────────────────────────

local function sendToClient(name, target, payload)
    local id = tonumber(target)
    for _, vm in pairs(W.vms) do
        if vm.side == 'client' and not vm.dead and (id == -1 or vm.playerId == id) then
            local copy = deepcopy(payload)
            W.queue[#W.queue + 1] = { run = function() vm.net(name, nil, copy) end }
        end
    end
    W.netLog[#W.netLog + 1] = { dir = 'toClient', name = name, target = id, payload = deepcopy(payload), at = W.now }
end

local function sendToServer(fromId, name, ...)
    local args = deepcopy(table.pack(...))
    -- `W.lostToServer[name]`: a client's word that never reaches the server (a
    -- game without it, say), for a suite that tests the server without it.
    if W.lostToServer ~= nil and W.lostToServer[name] then
        W.netLog[#W.netLog + 1] = { dir = 'toServer', name = name, from = fromId, payload = deepcopy(args[1]),
            at = W.now, lost = true }
        return
    end
    for _, vm in pairs(W.vms) do
        if vm.side == 'server' and not vm.dead then
            W.queue[#W.queue + 1] = { run = function() vm.net(name, fromId, table.unpack(args, 1, args.n)) end }
        end
    end
    W.netLog[#W.netLog + 1] = { dir = 'toServer', name = name, from = fromId, payload = deepcopy(args[1]), at = W.now }
end

W.netLog = {}

--- The messages of one name, in order; `filter(entry)` narrows them.
function W.sent(name, filter)
    local out = {}
    for _, entry in ipairs(W.netLog) do
        if entry.name == name and (filter == nil or filter(entry)) then out[#out + 1] = entry end
    end
    return out
end

--- The last message of one name to one player.
function W.lastTo(name, playerId)
    local found = nil
    for _, entry in ipairs(W.netLog) do
        if entry.name == name and entry.dir == 'toClient' and (entry.target == playerId or entry.target == -1) then
            found = entry
        end
    end
    return found
end

-- ── a VM ─────────────────────────────────────────────────────────────────────

-- THE HOST'S SANDBOX. A name the host takes away from resource scripts is nil
-- here too, so a resource that reaches for one fails in this world as it does
-- in the game: open77_avdoor 1.5.1's `setmetatable` stopped it loading on every
-- client ("resource activation failed", Staging, 2026-10-28) and passed here.
-- The client's list is scripting/src/ResourceHost.cpp's `OpenSandbox` (its
-- coroutine library without create, resume and wrap; its string library
-- without dump); the server's is the server guide's "What the sandbox provides"
-- (setmetatable and getmetatable survive there).
local SANDBOX_REMOVED = {
    client = { 'collectgarbage', 'dofile', 'load', 'loadfile', 'getmetatable', 'setmetatable', 'io', 'os', 'debug',
        'package' },
    server = { 'collectgarbage', 'dofile', 'load', 'loadfile', 'io', 'os', 'debug', 'package', 'require' },
}
local function sandboxLibrary(library, without)
    local copy = {}
    for key, value in pairs(library) do copy[key] = value end
    for _, key in ipairs(without) do copy[key] = nil end
    return copy
end
local CLIENT_COROUTINE = sandboxLibrary(coroutine, { 'create', 'resume', 'wrap' })
local CLIENT_STRING = sandboxLibrary(string, { 'dump' })

local function newVm(name, side, resource, playerId)
    local hidden = {}
    for _, key in ipairs(SANDBOX_REMOVED[side] or {}) do hidden[key] = true end
    local env = setmetatable({}, { __index = function(_, key)
        if hidden[key] then return nil end
        return _G[key]
    end })
    env._G = env
    if side == 'client' then
        env.coroutine = CLIENT_COROUTINE
        env.string = CLIENT_STRING
    end
    local vm = { name = name, side = side, resource = resource, playerId = playerId, env = env,
        handlers = {}, nets = {}, commands = {}, exports = {}, dead = false }
    W.vms[name] = vm

    function vm.fire(event, ...)
        local list = vm.handlers[event]
        if list == nil then return end
        local args = table.pack(...)
        for _, fn in ipairs(list) do
            nextOrigin = 'event ' .. tostring(event) .. ' ' .. originOf(fn)
            spawn(vm, function() fn(table.unpack(args, 1, args.n)) end)
        end
    end

    function vm.net(event, from, ...)
        local fn = vm.nets[event]
        if fn == nil then return end
        local args = table.pack(...)
        nextOrigin = 'net ' .. tostring(event) .. ' ' .. originOf(fn)
        spawn(vm, function()
            env.source = from
            local ok, err = pcall(fn, table.unpack(args, 1, args.n))
            env.source = nil
            if not ok then error(err, 0) end
        end)
    end

    env.CreateThread = function(fn) spawn(vm, fn) end
    env.Wait = function(ms)
        local entry = currentEntry()
        if entry == nil then error('Wait outside a thread') end
        local wake = W.now + math.max(0, tonumber(ms) or 0)
        -- A client of a player with a frame time runs on frames, as a host does:
        -- a wait ends on the first frame boundary after it, and never in the
        -- frame it was asked in.
        local player = side == 'client' and W.players[playerId] or nil
        local frame = player ~= nil and player.frameMs or nil
        if frame ~= nil and frame > 0 then
            local boundary = math.ceil(wake / frame) * frame
            if boundary <= W.now then boundary = (math.floor(W.now / frame) + 1) * frame end
            wake = boundary
        end
        entry.wakeAt = wake
        coroutine.yield()
    end
    env.GetCurrentResourceName = function() return resource end
    env.GetInvokingResource = function() return W.invoker end
    env.GetResourceState = function(other) return W.resourceStates[other] or 'missing' end
    env.AddEventHandler = function(event, fn)
        vm.handlers[event] = vm.handlers[event] or {}
        table.insert(vm.handlers[event], fn)
    end
    env.RegisterNetEvent = function(event, fn) if fn ~= nil then vm.nets[event] = fn end end
    env.TriggerEvent = function(event, ...)
        local args = table.pack(...)
        -- The host bus: every resource of this side that handles it, next tick.
        for _, other in pairs(W.vms) do
            if other.side == side and not other.dead and (side == 'server' or other.playerId == playerId) then
                W.queue[#W.queue + 1] = { run = function() other.fire(event, table.unpack(args, 1, args.n)) end }
            end
        end
        W.netLog[#W.netLog + 1] = { dir = 'local', name = event, vm = name, payload = deepcopy(args) }
        return true
    end
    env.RegisterCommand = function(command, fn, restricted) vm.commands[command] = { fn = fn, restricted = restricted } end
    env.exports = function(exportName, fn) vm.exports[exportName] = fn end
    env.print = function(...)
        local parts = {}
        for i = 1, select('#', ...) do parts[#parts + 1] = tostring((select(i, ...))) end
        W.logs[#W.logs + 1] = { vm = name, level = 'print', text = table.concat(parts, '\t'), at = W.now }
    end
    if side == 'server' then
        env.TriggerClientEvent = function(event, target, payload) sendToClient(event, target, payload) end
    else
        env.TriggerServerEvent = function(event, ...)
            -- A game still loading cannot send (`netReadyAt`); a hello may be
            -- lost on the way (`W.dropHello[playerId]`): sent, never heard.
            local p = W.players[playerId]
            if p ~= nil and p.netReadyAt ~= nil and W.now < p.netReadyAt then return false, 'network_unavailable' end
            if W.dropHello ~= nil and W.dropHello[playerId] and event == 'open77_avdoor:hello' then
                W.droppedHellos = (W.droppedHellos or 0) + 1
                return true
            end
            -- Any event lost on the way (`W.dropEvents[event]`): sent, never heard.
            if W.dropEvents ~= nil and W.dropEvents[event] then
                W.droppedEvents = (W.droppedEvents or 0) + 1
                return true
            end
            sendToServer(playerId, event, ...)
            return true
        end
    end
    return vm
end

--- Loads the real resource files into a VM.
function W.load(vm, root, files)
    for _, file in ipairs(files) do
        local chunk, err = loadfile(root .. '/' .. file, 't', vm.env)
        assert(chunk, err)
        local ok, failure = pcall(chunk)
        assert(ok, file .. ': ' .. tostring(failure))
    end
    W.run()
end

--- Stops a VM: its own `onResourceStop`/`onClientResourceStop` handlers run
--- first, while it can still run code, then it is gone.
function W.stop(vm)
    local event = vm.side == 'server' and 'onResourceStop' or 'onClientResourceStop'
    for _, fn in ipairs(vm.handlers[event] or {}) do
        spawn(vm, function() fn(vm.resource, 'manual') end)
    end
    W.run()
    vm.dead = true
    W.vms[vm.name] = nil
    -- Other VMs hear of it.
    for _, other in pairs(W.vms) do
        if other.side == vm.side and not other.dead and (vm.side == 'server' or other.playerId == vm.playerId) then
            other.fire(event, vm.resource, 'manual')
        end
    end
    W.run()
end

-- ── the server's natives ─────────────────────────────────────────────────────

local function serverSnapshot(vehicle)
    return {
        id = vehicle.id, record = vehicle.record,
        x = vehicle.x, y = vehicle.y, z = vehicle.z,
        position = { x = vehicle.x, y = vehicle.y, z = vehicle.z },
        heading = vehicle.heading, yaw = vehicle.heading, bucket = vehicle.bucket, speed = vehicle.speed,
        occupants = occupantsOf(vehicle), physicsOwner = vehicle.physicsOwner, authorityEpoch = vehicle.epoch,
        frozen = vehicle.frozen, destroyed = vehicle.destroyed, locked = vehicle.locked,
    }
end

local function validId(id, what)
    local number = tonumber(id)
    if number == nil or number < 1 or number ~= math.floor(number) then
        W.violations[#W.violations + 1] = what .. '(' .. tostring(id) .. ')'
        error('id must be positive', 0)
    end
    return number
end

function W.server(resource, root, files)
    local vm = newVm('server:' .. resource, 'server', resource, nil)
    local env = vm.env
    env.Open77 = {
        time = { monotonic = function() return W.now / 1000.0 end },
        log = logger(vm),
        players = {
            all = function()
                local out = {}
                for id in pairs(W.players) do out[#out + 1] = id end
                table.sort(out)
                return out
            end,
            position = function(id)
                local player = W.players[validId(id, 'players.position')]
                if player == nil then return nil end
                return { x = player.x, y = player.y, z = player.z, bucket = player.bucket }
            end,
            isDead = function(id)
                local player = W.players[validId(id, 'players.isDead')]
                return player ~= nil and player.dead == true
            end,
            setVisible = function(id, visible)
                local player = W.players[validId(id, 'players.setVisible')]
                if player == nil then return false, 'player_not_found' end
                if type(visible) ~= 'boolean' then return false, 'invalid_argument' end
                W.visibility[player.id] = visible
                W.visibilityLog[#W.visibilityLog + 1] = { player = player.id, visible = visible, at = W.now }
                return true
            end,
        },
        vehicles = {
            flags = { frozen = 2048 },
            get = function(id)
                local vehicle = W.find(id)
                if vehicle == nil then return nil end
                return serverSnapshot(vehicle)
            end,
            all = function()
                local out = {}
                for _, vehicle in pairs(W.vehicles) do out[#out + 1] = serverSnapshot(vehicle) end
                table.sort(out, function(a, b) return a.id < b.id end)
                return out
            end,
            -- Who simulates a hull (`Open77.vehicles.owner`): the lease, and the
            -- platform's controller of it (`ownerDriver`, set by a suite: "any
            -- occupant of an AV").
            owner = function(id)
                local vehicle = W.find(id)
                if vehicle == nil then return nil, 'vehicle_not_found' end
                local leased = vehicle.physicsOwner or 0
                return { physicsOwner = leased, authorityPlayerId = leased, driver = vehicle.ownerDriver,
                    steward = false, aiDriven = false, epoch = vehicle.epoch, reason = 'none' }
            end,
            getPlayerSeat = function(playerId)
                local player = W.players[tonumber(playerId) or -1]
                if player == nil or player.seat == nil then return nil end
                local vehicle = W.find(player.seat.vehicleId)
                return { playerId = player.id, vehicleId = player.seat.vehicleId, seat = player.seat.seat,
                    exiting = vehicle ~= nil and vehicle.exiting[player.seat.seat] == true or false }
            end,
            seatFree = function(id, seat)
                local vehicle = W.find(id)
                if vehicle == nil then return false end
                return vehicle.seats[seat] == nil
            end,
            isLocked = function(id)
                local vehicle = W.find(id)
                return vehicle ~= nil and vehicle.locked == true
            end,
            isLockedForPlayer = function(id, playerId)
                local vehicle = W.find(id)
                if vehicle == nil then return nil end
                local exception = vehicle.lockedFor[tonumber(playerId)]
                if exception ~= nil then return exception end
                return vehicle.locked == true
            end,
            -- One player's view of the lock (the platform's per-player
            -- exception): true/false pins it, nil drops it. Every call is
            -- logged for the suite (`W.lockCalls`).
            setLockedForPlayer = (not W.noPlayerLocks) and function(id, playerId, locked)
                local vehicle = W.find(id)
                if vehicle == nil then return false, 'vehicle_not_found' end
                local p = tonumber(playerId)
                if p == nil or W.players[p] == nil then return false, 'invalid_player_id' end
                if locked ~= nil and type(locked) ~= 'boolean' then return false, 'invalid_argument' end
                vehicle.lockedFor[p] = locked
                W.lockCalls = W.lockCalls or {}
                W.lockCalls[#W.lockCalls + 1] = { id = vehicle.id, player = p, locked = locked, at = W.now }
                return true
            end or nil,
            clearLockedForPlayer = (not W.noPlayerLocks) and function(id, playerId)
                local vehicle = W.find(id)
                if vehicle == nil then return false, 'vehicle_not_found' end
                local p = tonumber(playerId)
                if p == nil then return false, 'invalid_player_id' end
                vehicle.lockedFor[p] = nil
                W.lockCalls = W.lockCalls or {}
                W.lockCalls[#W.lockCalls + 1] = { id = vehicle.id, player = p, cleared = true, at = W.now }
                return true
            end or nil,
            setLocked = function(id, locked)
                local vehicle = W.find(id)
                if vehicle == nil then return false, 'vehicle_not_found' end
                vehicle.locked = locked == true
                return true
            end,
            setLockedForAll = function(id, locked)
                local vehicle = W.find(id)
                if vehicle == nil then return false, 'vehicle_not_found' end
                vehicle.locked = locked == true
                vehicle.lockedFor = {}
                return true
            end,
            isFrozen = function(id)
                local vehicle = W.find(id)
                if vehicle == nil then return nil end
                return vehicle.frozen
            end,
            -- THE FORCED EXIT (VehicleSeatService, the client's reconciliation):
            -- the order is durable and the leaving game unmounts the body at
            -- once (`isInstant`) -- no exit workspot -- a frame and a round trip
            -- later (`W.forcedExitMs`, 60). `W.forcedExits` keeps each order.
            forcePlayerOutOfVehicle = function(playerId, vehicleId)
                local player = W.players[tonumber(playerId) or -1]
                if player == nil then return false, 'invalid_player_id' end
                if player.seat == nil then return false, 'not_seated' end
                if vehicleId ~= nil and not W.find(vehicleId) then return false, 'invalid_vehicle_id' end
                if vehicleId ~= nil and W.find(vehicleId) ~= W.find(player.seat.vehicleId) then
                    return false, 'invalid_vehicle_id'
                end
                W.forcedExits = W.forcedExits or {}
                W.forcedExits[#W.forcedExits + 1] = { playerId = player.id, vehicleId = player.seat.vehicleId,
                    seat = player.seat.seat, at = W.now }
                W.after(W.forcedExitMs or 60, function()
                    if player.seat ~= nil then W.leave(player.id, { forced = true }) end
                end)
                return true
            end,
            warpPlayerIntoVehicle = function(playerId, vehicleId, seat, options)
                local player = W.players[tonumber(playerId) or -1]
                local vehicle = W.find(vehicleId)
                if player == nil then return false, 'player_not_found' end
                if vehicle == nil then return false, 'vehicle_not_found' end
                if vehicle.destroyed then return false, 'vehicle_destroyed' end
                if vehicle.seats[seat] ~= nil then return false, 'seat_occupied' end
                if player.bucket ~= vehicle.bucket and not (type(options) == 'table' and options.moveBucket) then
                    return false, 'wrong_bucket'
                end
                W.warps = W.warps or {}
                W.warps[#W.warps + 1] = { playerId = player.id, vehicleId = vehicle.id, seat = seat,
                    options = deepcopy(options), at = W.now }
                W.seat(player.id, vehicle.id, seat)
                return true
            end,
            openDoor = function(id, door)
                local vehicle = W.find(id)
                if vehicle == nil then return false, 'vehicle_not_found' end
                vehicle.doors[door] = true
                W.doorLog = W.doorLog or {}
                W.doorLog[#W.doorLog + 1] = { id = vehicle.id, door = door, open = true, at = W.now }
                return true
            end,
            closeDoor = function(id, door)
                local vehicle = W.find(id)
                if vehicle == nil then return false, 'vehicle_not_found' end
                vehicle.doors[door] = false
                W.doorLog = W.doorLog or {}
                W.doorLog[#W.doorLog + 1] = { id = vehicle.id, door = door, open = false, at = W.now }
                return true
            end,
            isDoorOpen = function(id, door)
                local vehicle = W.find(id)
                if vehicle == nil then return nil end
                return vehicle.doors[door] == true
            end,
            setTransform = function(id, transform)
                local vehicle = W.find(id)
                if vehicle == nil then return false end
                local t = type(transform.position) == 'table' and transform.position or transform
                vehicle.x = tonumber(t.x) or vehicle.x
                vehicle.y = tonumber(t.y) or vehicle.y
                vehicle.z = tonumber(t.z) or vehicle.z
                -- A missing yaw becomes 0, not the current heading.
                vehicle.heading = tonumber(transform.yaw) or 0.0
                vehicle.epoch = vehicle.epoch + 1
                -- A re-published hull is drawn where it is by every game that drew it off.
                vehicle.drawnOffsetFor = nil
                vehicle.transforms[#vehicle.transforms + 1] = { x = vehicle.x, y = vehicle.y, z = vehicle.z,
                    yaw = vehicle.heading, at = W.now, hadYaw = transform.yaw ~= nil }
                -- THE LEASE REVOKED (`revokeOnTransform`, as the platform does:
                -- every server pose is a `serverrevoke`): simulated by nobody
                -- until a game claims it back (`setFrozen` below).
                if vehicle.revokeOnTransform and vehicle.physicsOwner ~= 0 then
                    vehicle.physicsOwner = 0
                    vehicle.revokes = (vehicle.revokes or 0) + 1
                end
                for seat, playerId in pairs(vehicle.seats) do
                    local player = W.players[playerId]
                    -- `bodyStuck`: a game whose engine does not carry the body
                    -- along (its copy of the hull moves, the body does not).
                    if player ~= nil and not player.bodyStuck then
                        player.x, player.y, player.z = seatPoint(vehicle, seat)
                    end
                end
                return true
            end,
            setFrozen = function(id, frozen)
                local vehicle = W.find(id)
                if vehicle == nil then return false, 'vehicle_not_found' end
                vehicle.frozen = frozen == true
                vehicle.frozenLog[#vehicle.frozenLog + 1] = { frozen = vehicle.frozen, at = W.now }
                -- Unfrozen, a revoked hull is claimed back by the game that flies
                -- it (`reclaimBy`, else whoever sits in the pilot seat)
                -- `reclaimMs` later -- never by a game that `neverReclaims` (one
                -- stuck not ready, Staging 2026-10-30 17:15:07).
                if not vehicle.frozen and vehicle.revokeOnTransform then
                    W.after(vehicle.reclaimMs or 300, function()
                        if vehicle.frozen or vehicle.physicsOwner ~= 0 then return end
                        local by = vehicle.reclaimBy or vehicle.seats.seat_front_left
                        local player = by ~= nil and W.players[by] or nil
                        if player == nil or player.neverReclaims then return end
                        vehicle.physicsOwner = player.id
                        vehicle.epoch = vehicle.epoch + 1
                    end)
                end
                return true
            end,
            -- The platform's election, asked by name (`requestAuthority`): every
            -- ask logged (`W.authorityAsks`); `refuseAuthority` refuses it by
            -- that reason; the player who has it already is answered so.
            requestAuthority = function(id, playerId)
                local vehicle = W.find(id)
                if vehicle == nil then return nil, 'vehicle_not_found' end
                local player = W.players[tonumber(playerId) or -1]
                if player == nil then return nil, 'invalid_player_id' end
                W.authorityAsks = W.authorityAsks or {}
                W.authorityAsks[#W.authorityAsks + 1] = { id = vehicle.id, player = player.id, at = W.now }
                if vehicle.refuseAuthority ~= nil then return nil, vehicle.refuseAuthority end
                if vehicle.physicsOwner == player.id then
                    return { physicsOwner = player.id, authorityPlayerId = player.id, epoch = vehicle.epoch }, 'already_owner'
                end
                vehicle.physicsOwner = player.id
                vehicle.epoch = vehicle.epoch + 1
                return { physicsOwner = player.id, authorityPlayerId = player.id, epoch = vehicle.epoch, reason = 'none' }
            end,
        },
        locomotion = W.locomotion ~= nil and {
            -- The host's rules as the custom-locomotion guide states them: a
            -- registered style, a ready living player, one owner per player;
            -- a clip only for the owner, on a body outside any vehicle.
            set = function(id, style, options)
                local player = W.players[validId(id, 'locomotion.set')]
                if player == nil then return false, 'player_unavailable' end
                -- Not ready yet (1.7.6): a player who joined dead, or whose
                -- hello came before the game was up.
                if player.notReadyUntil ~= nil and W.now < player.notReadyUntil then
                    return false, 'player_unavailable'
                end
                if player.dead then return false, 'player_not_alive' end
                if not W.locomotion.registered[style] then return false, 'locomotion_package_unavailable' end
                local current = W.locomotion.assignments[player.id]
                if current ~= nil and current.owner ~= resource then return false, 'locomotion_owned_by_other_resource' end
                if current ~= nil and current.style == style then return true, current.revision end
                -- A style given rebuilds the body every game draws: this
                -- player's own stand-in is despawned, and made again at the
                -- next third person (Staging, 2026-10-29, 18:44:27.980).
                if player.proxy ~= nil then
                    player.proxy = nil
                    player.proxyDrops = (player.proxyDrops or 0) + 1
                end
                W.locomotion.serial = (W.locomotion.serial or 0) + 1
                W.locomotion.assignments[player.id] = { style = style, owner = resource,
                    revision = W.locomotion.serial, options = deepcopy(options), at = W.now }
                W.locomotion.sets = (W.locomotion.sets or 0) + 1
                return true, W.locomotion.serial
            end,
            get = function(id)
                local player = W.players[validId(id, 'locomotion.get')]
                if player == nil then return nil, 'player_unavailable' end
                local current = W.locomotion.assignments[player.id]
                if current == nil then return nil end
                return { player = player.id, style = current.style, packageRevision = 'rev', revision = current.revision,
                    resetOnDeath = false }
            end,
            playClip = function(id, clip, options)
                local player = W.players[validId(id, 'locomotion.playClip')]
                if player == nil then return false, 'player_unavailable' end
                local current = W.locomotion.assignments[player.id]
                if current == nil then return false, 'locomotion_not_selected' end
                if current.owner ~= resource then return false, 'locomotion_owned_by_other_resource' end
                -- The host's own word for a body that is not ready, not alive or
                -- in a vehicle (LocomotionClips.PlayClip): one reason for all three.
                if player.dead or player.seat ~= nil then return false, 'player_unavailable' end
                if W.locomotion.clips[current.style] ~= nil and not W.locomotion.clips[current.style][clip] then
                    return false, 'clip_unavailable'
                end
                W.locomotion.handle = (W.locomotion.handle or 0) + 1
                W.locomotion.played = W.locomotion.played or {}
                W.locomotion.played[#W.locomotion.played + 1] = { player = player.id, clip = clip,
                    options = deepcopy(options), at = W.now, owner = resource,
                    x = player.x, y = player.y, z = player.z, yaw = player.yaw }
                return true, W.locomotion.handle
            end,
        } or nil,
        effects = {
            sound = function(target, event, options)
                W.sounds[#W.sounds + 1] = { target = deepcopy(target), event = event, options = deepcopy(options) }
                return true
            end,
        },
        world = {
            -- The observer-based ground query: it WAITS for a game's answer.
            groundZ = function(position, options)
                local entry = currentEntry()
                if entry == nil then return nil, 'await_requires_scheduler_coroutine' end
                options = options or {}
                local observer = tonumber(options.playerId)
                if observer ~= nil then
                    if W.players[observer] == nil then return nil, 'player_not_found' end
                    W.groundAsks = (W.groundAsks or 0) + 1
                    if W.observerDown[observer] then
                        env.Wait(tonumber(options.timeout) or 3000)
                        return nil, 'callback_timeout'
                    end
                else
                    local near = false
                    for _, player in pairs(W.players) do
                        local dx, dy = player.x - position.x, player.y - position.y
                        if dx * dx + dy * dy <= (options.radius or 150) ^ 2 then near = true end
                    end
                    if not near then return nil, 'no_observer' end
                end
                env.Wait(20)
                local z = W.ground(position.x, position.y)
                if z == nil then return nil, 'no_ground' end
                return z, { playerId = observer }
            end,
        },
        exports = {
            call = function(other, exportName, ...)
                local target = W.vms['server:' .. other]
                if target == nil or target.exports[exportName] == nil then return nil, 'export_not_found' end
                local args = table.pack(...)
                local promise = { done = false }
                spawn(target, function()
                    local before = W.invoker
                    W.invoker = resource
                    promise.values = table.pack(target.exports[exportName](table.unpack(args, 1, args.n)))
                    W.invoker = before
                    promise.done = true
                end)
                function promise:await()
                    while not self.done do env.Wait(10) end
                    return table.unpack(self.values, 1, self.values.n)
                end
                return promise
            end,
        },
    }
    W.load(vm, root, files)
    return vm
end

-- ── a client's natives ───────────────────────────────────────────────────────

local function streamedFor(player, vehicle)
    local dx, dy, dz = player.x - vehicle.x, player.y - vehicle.y, player.z - vehicle.z
    return player.bucket == vehicle.bucket and dx * dx + dy * dy + dz * dz <= 425 * 425
end

--- Where a game draws a hull: where it is, unless a suite says it drifted --
--- on every game (`drawnOffset`) or on one player's (`drawnOffsetFor[id]`,
--- which the server's next `setTransform` of the hull puts right).
local function drawnAt(vehicle, player)
    local offset = vehicle.drawnOffset or { x = 0, y = 0, z = 0 }
    local own = player ~= nil and vehicle.drawnOffsetFor ~= nil and vehicle.drawnOffsetFor[player.id] or nil
    return { x = vehicle.x + offset.x + (own and own.x or 0), y = vehicle.y + offset.y + (own and own.y or 0),
        z = vehicle.z + offset.z + (own and own.z or 0) }
end

--- The package's clips (open77_avexit), as shared/core.lua's `WALK_CLIPS`:
--- the door's end of each against the entity (an exit's first frame, an
--- enter's last; a seat clip's last frame, 1.2.0 and 1.3.0, in the seat), and
--- the clip's length.
W.CLIPS = {
    enter = { seconds = 2.6, right = 0.150, forward = 1.1695, rise = 0.525, first = true },
    step = { seconds = 4.3, right = 0.643, forward = -2.386, rise = 0.5 },
    sit = { seconds = 5.6, right = -2.2757, forward = 0.5945, rise = 0.9598, turn = -14.773, first = true, seat = true },
    step_m = { seconds = 4.3, right = -0.643, forward = -2.386, rise = 0.5 },
    couch = { seconds = 4.4, right = 0.4473, forward = 1.9519, rise = 0.96, turn = 90.0, first = true, seat = true },
}

--- Where a game draws a body: where it is, unless a suite says that game
--- draws it off (`drawnOffsetFor[viewerId]`).
function W.drawnBody(target, viewer)
    local off = target.drawnOffsetFor ~= nil and viewer ~= nil and target.drawnOffsetFor[viewer.id] or nil
    return { x = target.x + (off and off.x or 0), y = target.y + (off and off.y or 0), z = target.z + (off and off.z or 0) }
end

--- The heading a game draws a body at: its own, or `drawnFor[viewerId].yaw`.
function W.drawnYaw(target, viewer)
    if viewer ~= nil and target ~= viewer then
        local drawn = target.drawnFor[viewer.id]
        if drawn ~= nil and drawn.yaw ~= nil then return drawn.yaw % 360.0 end
    end
    return (target.yaw or 0.0) % 360.0
end

--- The exit clip a body plays now, or nil.
function W.clipNow(target)
    if W.locomotion == nil or W.locomotion.played == nil then return nil end
    for i = #W.locomotion.played, 1, -1 do
        local entry = W.locomotion.played[i]
        local spec = W.CLIPS[entry.clip]
        if entry.player == target.id and spec ~= nil and W.now >= entry.at and W.now < entry.at + spec.seconds * 1000.0 then
            return entry
        end
    end
    return nil
end

--- Who sits in a hull, as the client snapshot lists them.
local function occupantsOf(vehicle)
    local out = {}
    for seat, playerId in pairs(vehicle.seats) do
        out[#out + 1] = { playerId = playerId, seat = seat, exiting = vehicle.exiting[seat] == true }
    end
    table.sort(out, function(a, b) return a.seat < b.seat end)
    return out
end

--- Whether a game has no engine entity for a hull (`entityZeroFor[playerId]`):
--- its snapshot's `entity` is 0 and a `vehicle` geometry read is refused.
local function entityZero(player, vehicle)
    return vehicle.entityZeroFor ~= nil and vehicle.entityZeroFor[player.id] == true
end

local function clientSnapshot(player, vehicle)
    if not streamedFor(player, vehicle) then return nil end
    -- `netOffsetFor[playerId]`: where that game's own newest sample has the hull,
    -- off its true place (a sample taken while the engine dragged it).
    local net = vehicle.netOffsetFor ~= nil and vehicle.netOffsetFor[player.id] or nil
    local zero = entityZero(player, vehicle)
    return {
        id = vehicle.id, record = vehicle.record, entity = zero and 0 or ('veh:' .. key(vehicle.id)), streamed = not zero,
        locallyOwned = vehicle.physicsOwner == player.id,
        position = { x = vehicle.x + (net and net.x or 0), y = vehicle.y + (net and net.y or 0),
            z = vehicle.z + (net and net.z or 0) }, heading = vehicle.heading,
        yaw = vehicle.heading, speed = vehicle.speed, physicsOwner = vehicle.physicsOwner,
        authorityEpoch = vehicle.epoch, frozen = vehicle.frozen, engineOn = vehicle.engineOn,
        packetAgeMs = 40, extrapolating = false, occupants = occupantsOf(vehicle),
    }
end

local function vehicleOfRef(ref)
    if type(ref) == 'string' then return W.find(ref:match('^veh:(%d+)$')) end
    if type(ref) == 'table' and ref.kind == 'vehicle' then return W.find(ref.id) end
    return nil
end

--- THE PLATFORM'S ENTITY 0 is the local player (client/src/api/ZoneGeometry.cpp:
--- `handle.value==0 ? LocalPlayer() : ...`): an `entity` read of 0, bare or as
--- `{ kind = 'entity', id = 0 }`, answers the asking player's own body.
local function isEntityZero(ref)
    if type(ref) == 'number' then return ref == 0 end
    return type(ref) == 'table' and ref.kind == 'entity' and tonumber(ref.id) == 0
end

function W.client(playerId, resource, root, files)
    local player = W.players[playerId]
    local vm = newVm(('client:%s:%d'):format(resource, playerId), 'client', resource, playerId)
    local env = vm.env
    local function handle(prefix)
        player.nextHandle = player.nextHandle + 1
        return prefix .. ':' .. player.nextHandle
    end
    -- The host's clock moves on inside a pass (`clockStepMs`: so much a read):
    -- a pass that reads it twice may see two milliseconds.
    local clockAt, clockReads = nil, 0
    env.Open77 = {
        time = { monotonic = function()
            if player.clockStepMs == nil then return W.now / 1000.0 end
            if clockAt ~= W.now then clockAt, clockReads = W.now, 0 end
            clockReads = clockReads + 1
            return (W.now + clockReads * player.clockStepMs) / 1000.0
        end },
        log = logger(vm),
        session = {
            locale = function()
                if player.locale == false then return nil, 'locale_not_reported' end
                return deepcopy(player.locale)
            end,
            -- What the launcher told this game at its start (1.7.2's hello):
            -- `player.launcher` when a case sets it, else a launcher-started game.
            launcherContext = function()
                if player.launcher ~= nil then return deepcopy(player.launcher) end
                return { connectEndpoint = '127.0.0.1:11840', master = 'alpha',
                    serverId = '9dcd2e5a-57d5-4852-9458-ac23f748707e',
                    modsDigest = '08d1c8c2b95149426e652baa054e9c6084407a5794111b2ba44206c77c8d2ec1', launched = true }
            end,
        },
        -- The weapon (1.7.2: put away before the boarding step). `holster` is
        -- a request: the hands are empty `player.holsterMs` (400) later, never
        -- with `player.weaponStuck`; `player.holsterRefused` refuses it.
        weapons = {
            holster = function()
                if player.holsterRefused then return nil, 'permission_denied:player.weapons.edit' end
                W.holsters = (W.holsters or 0) + 1
                if player.weaponDrawn and not player.weaponStuck then
                    W.after(player.holsterMs or 400, function() player.weaponDrawn = false end)
                end
                return ('holster-%d'):format(W.holsters)
            end,
        },
        character = {
            position = function() return player.x, player.y, player.z end,
            isAlive = function() return not player.dead end,
            -- The engine's NoMovement restriction (`player.freeze`): the body held,
            -- its locomotion state -- and the ground under it -- untouched.
            setFrozen = player.noRestriction ~= true and function(frozen)
                if type(frozen) ~= 'boolean' then return false, 'invalid_argument' end
                player.frozenLog[#player.frozenLog + 1] = { restriction = frozen, at = W.now, grounded = W.grounded(player) }
                player.restricted = frozen
                return true, frozen
            end or nil,
            yaw = function() return player.yaw end,
            -- One body's snapshot (ResourceHost.cpp, `LuaCharacterState`): no
            -- argument or 0 is this player; another player's body by the entity
            -- id `players.entity` gave. `vehicle.mounted` is the engine's mount
            -- -- held by this game's own dismount for `dismountMs` after the
            -- seat emptied.
            state = function(entity)
                local target = player
                if entity ~= nil and tonumber(entity) ~= 0 then
                    target = W.players[(tonumber(entity) or 0) - W.PLAYER_ENTITY]
                    if target == nil then return nil, 'entity_not_found' end
                end
                W.stateReads = (W.stateReads or 0) + 1
                local mounted = target.seat ~= nil
                -- THE GAME'S OWN EXIT, ANIMATED (`W.leave` `animatedMs`): the
                -- engine keeps the body mounted, in the exit's workspot.
                local animated = target.animatedUntil ~= nil and W.now < target.animatedUntil
                if animated then mounted = true end
                if not mounted and target ~= player then
                    local untilAt = target.dismountUntil[player.id]
                    if untilAt ~= nil and W.now < untilAt then mounted = true end
                end
                local at = W.drawnBody(target, player)
                local drawn = target ~= player and target.drawnFor[player.id] or {}
                local yaw = W.drawnYaw(target, player)
                local r = math.rad(yaw)
                local grounded = drawn.grounded
                if grounded == nil then grounded = W.grounded(target) end
                return { isPlayer = target == player, attached = true, id = target == player and 0 or entity,
                    source = 'owned', owned = true, alive = not target.dead,
                    position = at, yaw = yaw, forward = { x = -math.sin(r), y = math.cos(r), z = 0 },
                    grounded = grounded, air = grounded and 'none' or 'falling', fall = grounded and 'none' or 'regular',
                    weapon = { known = true, drawn = drawn.weapon == true or target.weaponDrawn == true },
                    age = target ~= player and (drawn.ageMs or 40) / 1000.0 or 0.0,
                    inWorkspot = animated or (target.workspotFor ~= nil and target.workspotFor[player.id] == true) or false,
                    animation = '', vehicle = not (target.mountUnreadUntil ~= nil and W.now < target.mountUnreadUntil)
                        and { mounted = mounted, entity = 0, seat = '' } or nil }
            end,
            -- The slots an entity publishes (`world.transform`): an
            -- Excalibur's door slots and seats, a body's hips and head.
            bones = function(entity)
                if type(entity) == 'table' and entity.vehicleId ~= nil then
                    local vehicle = W.find(entity.vehicleId)
                    if vehicle == nil or not streamedFor(player, vehicle) then return nil, 'entity_not_streamed' end
                    local out = {}
                    if not vehicle.noDoorSlots and tostring(vehicle.record):lower():find('av_rayfield_excalibur', 1, true) then
                        for name in pairs(W.EXCALIBUR_SLOTS) do out[#out + 1] = name end
                    end
                    for seat in pairs(SEAT_OFFSET) do out[#out + 1] = seat end
                    table.sort(out)
                    return out
                end
                return { 'Head', 'Hips', 'LeftHand', 'RightHand' }
            end,
            -- One slot's world place: a door slot of the hull as THIS game draws
            -- it (`drawnTurnedFor[playerId]`: its mesh drawn facing the other
            -- way), or a body's hips -- 2.5 m from its feet's point at the
            -- step's first frame, coming in as the clip plays (an enter clip's
            -- going out to its door end as it plays), unless the clip
            -- is not drawn here (`drawnFor[viewer].noClip`; and never on this
            -- player's own body: its clip plays on the stand-in).
            bonePosition = function(entity, name)
                W.boneReads = (W.boneReads or 0) + 1
                if type(entity) == 'table' and entity.vehicleId ~= nil then
                    local vehicle = W.find(entity.vehicleId)
                    if vehicle == nil or not streamedFor(player, vehicle) then return nil, 'entity_not_streamed' end
                    local slot = W.EXCALIBUR_SLOTS[name]
                    if vehicle.noDoorSlots or slot == nil
                        or not tostring(vehicle.record):lower():find('av_rayfield_excalibur', 1, true) then
                        return nil, 'unknown_bone'
                    end
                    local at = drawnAt(vehicle, player)
                    local heading = vehicle.heading
                    if vehicle.drawnTurnedFor ~= nil and vehicle.drawnTurnedFor[player.id] then heading = heading + 180.0 end
                    local r = math.rad(heading)
                    local fx, fy = -math.sin(r), math.cos(r)
                    -- 1.7.10: the middle panel's slot as the door is drawn -- 0.13 m
                    -- up shut, 0.65 m down open (Staging, 2026-10-29) -- as the
                    -- network holds the trunk, unless this game draws it otherwise
                    -- (`drawnDoorFor[player] = 'open' | 'shut'`).
                    local z = slot.z
                    if name == 'door_b_01' then
                        local drawn = vehicle.drawnDoorFor ~= nil and vehicle.drawnDoorFor[player.id] or nil
                        local open = drawn == 'open' or (drawn == nil and vehicle.doors.trunk == true)
                        z = open and -0.65 or 0.13
                    end
                    return { x = at.x + slot.x * fy + slot.y * fx, y = at.y - slot.x * fx + slot.y * fy, z = at.z + z }
                end
                if tostring(name):lower() ~= 'hips' then return nil, 'unknown_bone' end
                local target = player
                if entity ~= nil and tonumber(entity) ~= 0 then
                    target = W.players[(tonumber(entity) or 0) - W.PLAYER_ENTITY]
                    if target == nil then return nil, 'entity_not_found' end
                end
                local at = W.drawnBody(target, player)
                local hips = { x = at.x, y = at.y, z = at.z + W.HIPS_HEIGHT }
                local drawn = target ~= player and target.drawnFor[player.id] or {}
                -- No clip is drawn on a body its own game has off the ground.
                if target ~= player and not drawn.noClip and W.grounded(target) then
                    local clip = W.clipNow(target)
                    if clip ~= nil then
                        local spec = W.CLIPS[clip.clip]
                        -- An exit clip comes in from its door end (its first frame);
                        -- an enter clip (`first`, 1.7.0) goes out to it.
                        local into = (W.now - clip.at) / (spec.seconds * 1000.0)
                        local left = spec.first and into or (1.0 - into)
                        local r = math.rad(W.drawnYaw(target, player))
                        local c, s = math.cos(r), math.sin(r)
                        hips.x = hips.x + (spec.right * c - spec.forward * s) * left
                        hips.y = hips.y + (spec.right * s + spec.forward * c) * left
                        hips.z = hips.z + spec.rise * left
                    end
                end
                return hips
            end,
        },
        perspective = player.noPerspective ~= true and {
            setThirdPerson = function(enabled, force)
                if type(enabled) ~= 'boolean' or (force ~= nil and type(force) ~= 'boolean') then
                    return false, 'invalid_perspective_arguments'
                end
                if player.perspectivePolicy == 'disabled' and enabled then return false, 'refused_by_policy' end
                if player.arbiter == 'stable157' then W.arbiterAt(player, W.now, W.arbiterRow(player)) end
                player.views[#player.views + 1] = { tps = enabled, force = force == true, at = W.now }
                local locked = force == true and (enabled and 'tps' or 'fpp') or nil
                if locked == 'tps' and player.lockedView ~= 'tps' then player.lockedAt = W.now end
                player.lockedView = locked
                return true
            end,
            clearThirdPersonOverride = function()
                if player.arbiter == 'stable157' then W.arbiterAt(player, W.now, W.arbiterRow(player)) end
                player.views[#player.views + 1] = { clear = true, at = W.now }
                player.lockedView = nil
                player.lockedAt = nil
                return true
            end,
            -- The arbiter's answer: a vehicle, then a foreign camera (the
            -- client's chase and legacy exit cameras) -- the fatal row, which
            -- lets go twelve frames after the last of them -- then a forced
            -- third person: committing, revealing (the first-person body, then
            -- the stand-in) and settled, `tpsReadyMs` (600 ms) after it began
            -- at the earliest.
            state = function()
                if player.arbiter == 'stable157' then
                    local a = W.arbiterAt(player, W.now, W.arbiterRow(player))
                    return { mode = a.mode, settled = a.transition == 'settled', transition = a.transition,
                        reason = a.reason, rule = a.reason, camera = a.mode == 'tps' and 'open77_rig'
                            or (a.reason == 'vehicle' and 'engine' or 'player_eyes'), body = a.body,
                        resourceForced = player.lockedView ~= nil, resourcePerspective = player.lockedView or 'none',
                        available = true, engaged = true }
                end
                local frame = W.frameOf(player)
                local function answer(mode, settled, reason, camera, body, transition)
                    return { mode = mode, settled = settled,
                        transition = transition or (settled and 'settled' or 'preparing'),
                        reason = reason, rule = reason, camera = camera, body = body,
                        resourceForced = player.lockedView ~= nil, resourcePerspective = player.lockedView or 'none' }
                end
                local function fatal()
                    player.tpsFrom = nil
                    local row = answer('fpp', true, 'fatal_state', 'player_eyes', 'player_body')
                    row.rule = 'fatal'
                    return row
                end
                if player.seat ~= nil and player.chaseCamera ~= true then
                    player.tpsFrom = nil
                    return answer('fpp', true, 'vehicle', 'engine', 'native')
                end
                if player.legacyCamera or player.chaseCamera
                    or (player.attachUntil ~= nil and W.now < player.attachUntil and player.lockedView == 'tps') then
                    -- A camera detached under a first-person decision breaks the
                    -- arbiter's single-camera invariant: the fatal row (Staging,
                    -- 2026-10-27, for the whole legacy exit camera), the foreign
                    -- camera row held behind it. So does the first-person
                    -- camera attached under its third-person one.
                    return fatal()
                end
                -- The row lets go after twelve clean frames.
                local clean = player.unblockedAt
                if player.attachUntil ~= nil and player.lockedView == 'tps' then
                    clean = math.max(clean or player.attachUntil, player.attachUntil)
                end
                if clean ~= nil and W.now < clean + W.FATAL_EXIT_FRAMES * frame then return fatal() end
                if player.lockedView == 'tps' then
                    local from = player.lockedAt or W.now
                    if clean ~= nil then from = math.max(from, clean + W.FATAL_EXIT_FRAMES * frame) end
                    player.tpsFrom = player.tpsFrom or from
                    if player.tpsReadyMs == false then
                        return answer('fpp', false, 'resource_forced', 'player_eyes', 'native')
                    end
                    local into = W.now - player.tpsFrom
                    local settle = math.max(player.tpsReadyMs or 600, 6 * frame)
                    if into >= settle then return answer('tps', true, 'resource_forced', 'open77_rig', 'proxy') end
                    if into >= settle - 2 * frame then
                        return answer('tps', false, 'resource_forced', 'open77_rig', 'proxy', 'revealing')
                    end
                    if into >= settle - 4 * frame then
                        return answer('tps', false, 'resource_forced', 'open77_rig', 'player_body', 'revealing')
                    end
                    if into >= settle - 6 * frame then
                        return answer('fpp', false, 'resource_forced', 'player_eyes', 'player_body', 'committing')
                    end
                    return answer('fpp', false, 'resource_forced', 'player_eyes', 'native')
                end
                player.tpsFrom = nil
                return answer('fpp', true, 'player_preference', 'player_eyes', 'native')
            end,
        } or nil,
        camera = {
            -- The legacy camera-only third person: off ends the exit camera.
            thirdPerson = function(enabled)
                player.cameraLog[#player.cameraLog + 1] = { legacy = false, on = enabled ~= false, at = W.now }
                if enabled == false then
                    -- Off is `SetThirdPerson(false)`: the body hidden and the
                    -- first-person camera attached. With no exit camera to end,
                    -- under a held third person, that is a camera the arbiter
                    -- did not choose. Under the chase camera it is undone by the
                    -- chase's next frame.
                    if not player.legacyCamera and not player.chaseCamera then W.attachFirstPerson(player) end
                    if player.legacyCamera then player.unblockedAt = W.now end
                    player.legacyCamera = false
                end
                return true
            end,
            -- The rendered camera: the chase camera 17 m behind the hull and
            -- 2.6 m over it, the legacy camera 2.5 m behind the body's eyes and
            -- 0.6 m over them, the rig 3 m behind (or round, orbiting) the body,
            -- or the eyes.
            view = player.noCameraView ~= true and function()
                local eyes = { x = player.x, y = player.y, z = player.z + 1.6 }
                local r = math.rad(player.yaw or 0)
                local fx, fy = -math.sin(r), math.cos(r)
                if player.chaseCamera then
                    local vehicle = player.lastHull ~= nil and W.find(player.lastHull) or nil
                    local hx, hy, hz = eyes.x, eyes.y, eyes.z
                    local vfx, vfy = fx, fy
                    if vehicle ~= nil then
                        hx, hy, hz = vehicle.x, vehicle.y, vehicle.z
                        vfx, vfy = axes(vehicle)
                    end
                    return { position = { x = hx - vfx * 17.0, y = hy - vfy * 17.0, z = hz + 2.6 },
                        forward = { x = vfx, y = vfy, z = 0 }, fov = 60 }
                end
                if player.legacyCamera then
                    return { position = { x = eyes.x - fx * 2.5, y = eyes.y - fy * 2.5, z = eyes.z + 0.6 },
                        forward = { x = fx, y = fy, z = 0 }, fov = 60 }
                end
                local state = W.vms[vm.name] ~= nil and env.Open77.perspective ~= nil and env.Open77.perspective.state() or nil
                if state ~= nil and state.mode == 'tps' then
                    local o = math.rad((player.yaw or 0) + (player.orbit or 0))
                    local ox, oy = -math.sin(o), math.cos(o)
                    return { position = { x = player.x - ox * 3.0, y = player.y - oy * 3.0, z = player.z + 1.5 },
                        forward = { x = ox, y = oy, z = 0 }, fov = 60 }
                end
                return { position = eyes, forward = { x = fx, y = fy, z = 0 }, fov = 60 }
            end or nil,
            -- The preview orbit: only on the rig (third person drawn).
            orbit = function(degrees)
                local state = env.Open77.perspective ~= nil and env.Open77.perspective.state() or nil
                if state == nil or state.camera ~= 'open77_rig' then
                    player.orbitLog[#player.orbitLog + 1] = { on = true, refused = true, at = W.now }
                    return false, 'perspective_not_third_person'
                end
                player.orbit = degrees
                player.orbitLog[#player.orbitLog + 1] = { on = true, degrees = degrees, at = W.now }
                -- A rig whose body follows its view turns the body with the swing.
                if player.orbitTurnsBody then
                    W.after(W.frameOf(player), function()
                        player.yaw = ((player.yaw or 0) + degrees) % 360.0
                        player.turnLog = player.turnLog or {}
                        player.turnLog[#player.turnLog + 1] = { why = 'orbit', yaw = player.yaw, at = W.now }
                    end)
                end
                return true
            end,
            clearOrbit = function()
                player.orbit = nil
                player.orbitLog[#player.orbitLog + 1] = { on = false, at = W.now }
                return true
            end,
        },
        players = {
            -- The entity id of a player's body on this game: 0 for this player
            -- (the reserved "me"), `player_not_streamed` for a body it does not
            -- draw (another bucket, out of range, or `unstreamedFor`).
            entity = function(id)
                local number = tonumber(id)
                if number == nil or number < 1 or number ~= math.floor(number) then return nil, 'invalid_player' end
                if number == player.id then return 0 end
                local other = W.players[number]
                if other == nil then return nil, 'unknown_player' end
                local dx, dy, dz = other.x - player.x, other.y - player.y, other.z - player.z
                if other.bucket ~= player.bucket or dx * dx + dy * dy + dz * dz > 425 * 425
                    or (other.unstreamedFor ~= nil and other.unstreamedFor[player.id]) then
                    return nil, 'player_not_streamed'
                end
                return W.PLAYER_ENTITY + number
            end,
            freezePosition = function(enabled)
                if type(enabled) ~= 'boolean' then return false, 'invalid_argument' end
                -- (`freezeRefuse`: the host refuses the hold, as for a body not ready.)
                if enabled and player.freezeRefuse ~= nil then return false, player.freezeRefuse end
                player.frozenLog[#player.frozenLog + 1] = { position = enabled, at = W.now,
                    grounded = W.grounded(player) }
                -- THE FORCED FREEZE TAKES THE BODY AS IT IS: off the ground, it
                -- stays off it while held (`W.grounded`).
                -- (`freezeLifts`: a game whose forced freeze takes it off the ground
                -- whatever it stood on.)
                if enabled and not player.frozenPosition then
                    if not W.grounded(player) or player.freezeLifts then
                        player.frozenAir = true
                    end
                end
                player.frozenPosition = enabled
                -- A body held in the air comes down once its place is let go --
                -- unless the native fade holds it still (it lands after it).
                if not enabled and (player.hovering or player.frozenAir) then
                    player.frozenAir = false
                    if W.screenHeld(player) then
                        player.screenAir = true
                        player.hovering, player.landAt = false, nil
                    else
                        player.hovering, player.landAt = false, W.now + W.LAND_MS
                        W.landLater(player)
                    end
                end
                return true
            end,
            freezeRotation = function(enabled)
                if type(enabled) ~= 'boolean' then return false, 'invalid_argument' end
                player.frozenLog[#player.frozenLog + 1] = { rotation = enabled, at = W.now }
                player.frozenRotation = enabled
                return true
            end,
        },
        vehicles = {
            get = function(id)
                local vehicle = W.find(id)
                if vehicle == nil then return nil end
                return clientSnapshot(player, vehicle)
            end,
            all = function()
                local out = {}
                for _, vehicle in pairs(W.vehicles) do
                    local snapshot = clientSnapshot(player, vehicle)
                    if snapshot ~= nil then out[#out + 1] = snapshot end
                end
                return out
            end,
            -- The host's own shape (`PushVehicleProximityEntry`): the identity,
            -- the place and the distance, `occupants` a COUNT; everything else is
            -- `get`'s.
            nearby = function(radius)
                local out = {}
                for _, vehicle in pairs(W.vehicles) do
                    local snapshot = clientSnapshot(player, vehicle)
                    if snapshot ~= nil then
                        local dx, dy, dz = player.x - vehicle.x, player.y - vehicle.y, player.z - vehicle.z
                        local distance = math.sqrt(dx * dx + dy * dy + dz * dz)
                        if distance <= radius then
                            out[#out + 1] = { id = snapshot.id, entity = snapshot.entity, engineEntity = 0,
                                record = snapshot.record, distance = distance, streamed = snapshot.streamed,
                                locked = vehicle.locked == true, occupants = #snapshot.occupants,
                                position = { x = vehicle.x, y = vehicle.y, z = vehicle.z } }
                        end
                    end
                end
                table.sort(out, function(a, b) return a.distance < b.distance end)
                return out
            end,
            -- A canonical door as the network holds it (the client's read).
            isDoorOpen = function(id, door)
                local vehicle = W.find(id)
                if vehicle == nil then return nil end
                return vehicle.doors[door] == true
            end,
            getPlayerSeat = function(playerId)
                -- Omitted: the local player; otherwise any replicated player's.
                local target = player
                if playerId ~= nil then
                    target = W.players[tonumber(playerId) or -1]
                    if target == nil then return nil end
                end
                if target.seat == nil then return nil end
                local vehicle = W.find(target.seat.vehicleId)
                return { playerId = target.id, vehicleId = target.seat.vehicleId, seat = target.seat.seat,
                    exiting = vehicle ~= nil and vehicle.exiting[target.seat.seat] == true or false }
            end,
            -- The client's presentation call (1.7.8): another player's body shown
            -- in the seat the ledger names, at once; refused when the ledger
            -- does not name that seat.
            warpPlayerIntoVehicle = function(playerId, vehicleId, seat)
                local target = W.players[tonumber(playerId) or -1]
                W.presented = W.presented or {}
                local ok = target ~= nil and target.seat ~= nil and tostring(target.seat.vehicleId) == tostring(vehicleId)
                    and target.seat.seat == seat
                W.presented[#W.presented + 1] = { viewer = player.id, player = tonumber(playerId), vehicleId = vehicleId,
                    seat = seat, at = W.now, ok = ok }
                if not ok then return false, 'occupancy_mismatch' end
                return true
            end,
        },
        world = {
            entityGeometry = function(ref)
                if isEntityZero(ref) then
                    W.selfGeometryAsks = (W.selfGeometryAsks or 0) + 1
                    local r = math.rad(player.yaw or 0)
                    return { attached = true, entity = 0, position = { x = player.x, y = player.y, z = player.z },
                        forward = { x = -math.sin(r), y = math.cos(r), z = 0 },
                        orientation = { x = 0.0, y = 0.0, z = math.sin(r * 0.5), w = math.cos(r * 0.5) },
                        -- A body's box: half a metre across, its feet on its origin.
                        bounds = { min = { x = -0.35, y = -0.25, z = 0.0 }, max = { x = 0.35, y = 0.25, z = 1.8 } } }
                end
                local vehicle = vehicleOfRef(ref)
                if vehicle == nil or not streamedFor(player, vehicle) then return nil, 'entity_geometry_unavailable' end
                if entityZero(player, vehicle) then return nil, 'entity_not_streamed' end
                local at = drawnAt(vehicle, player)
                local fx, fy = axes(vehicle)
                local r = math.rad(vehicle.heading)
                local orientation = { x = 0.0, y = 0.0, z = math.sin(r * 0.5), w = math.cos(r * 0.5) }
                -- The loaded mesh's box, a hull of half width `halfWidth` (2.5)
                -- and half length `halfLength` (5.0), 1.5 m above and below its
                -- origin, its centre `boxOffset` off it (in the hull's frame).
                -- The client answers it IN THE HULL'S OWN FRAME
                -- (client/src/api/ZoneGeometry.cpp); `W.boundsSpace = 'world'`
                -- answers the card's world box instead, turned by the heading.
                local hw, hl = vehicle.halfWidth or 2.5, vehicle.halfLength or 5.0
                local o = vehicle.boxOffset or { x = 0, y = 0, z = 0 }
                local bounds
                if W.boundsSpace == 'world' then
                    local hx = hl * math.abs(fx) + hw * math.abs(fy)
                    local hy = hl * math.abs(fy) + hw * math.abs(fx)
                    bounds = { min = { x = at.x - hx, y = at.y - hy, z = at.z - 1.5 },
                        max = { x = at.x + hx, y = at.y + hy, z = at.z + 1.5 } }
                else
                    bounds = { min = { x = o.x - hw, y = o.y - hl, z = o.z - 1.5 },
                        max = { x = o.x + hw, y = o.y + hl, z = o.z + 1.5 } }
                end
                return { attached = true, entity = vehicle.id, position = at, forward = { x = fx, y = fy, z = 0 },
                    orientation = orientation, bounds = bounds }
            end,
            -- Static only: terrain is not met; ground over the ray's start is
            -- not met either (the ray starts under it).
            groundZ = function(x, y, fromZ)
                W.rayCount = W.rayCount + 1
                local z = W.ground(x, y)
                if z ~= nil and fromZ ~= nil and z > fromZ then return nil end
                return z
            end,
            raycast = W.rays ~= nil and function(from, to, options)
                options = options or {}
                local groups = options.groups
                local static, terrain, dynamic = options.static ~= false, false, options.dynamic ~= false
                if W.rays == 'groups' and groups ~= nil then
                    if options.static ~= nil or options.dynamic ~= nil then return nil, 'collision_groups_conflict' end
                    if type(groups) ~= 'table' or #groups == 0 or #groups > 16 then return nil, 'invalid_collision_groups' end
                    static, dynamic = false, false
                    for _, name in ipairs(groups) do
                        if name == 'Static' then static = true
                        elseif name == 'Terrain' then terrain = true
                        elseif name == 'Dynamic' or name == 'Vehicle' then dynamic = true
                        else return nil, 'invalid_collision_group' end
                    end
                end
                W.rayCount = W.rayCount + 1
                -- Straight down only: the rays these suites cast.
                if from.x ~= to.x or from.y ~= to.y or to.z >= from.z then return { hit = false } end
                local best = nil
                local function meet(z)
                    if z ~= nil and z <= from.z and z >= to.z and (best == nil or z > best) then best = z end
                end
                if static then meet(W.ground(from.x, from.y)) end
                if terrain and W.terrainAt ~= nil then meet(W.terrainAt(from.x, from.y)) end
                if dynamic then
                    -- A hull's box (as entityGeometry draws it), met on its top.
                    for _, vehicle in pairs(W.vehicles) do
                        local at = drawnAt(vehicle, player)
                        local fx, fy = axes(vehicle)
                        local hw, hl = vehicle.halfWidth or 2.5, vehicle.halfLength or 5.0
                        local dx, dy = from.x - at.x, from.y - at.y
                        local along, across = dx * fx + dy * fy, dx * -fy + dy * fx
                        if math.abs(along) <= hl and math.abs(across) <= hw and at.z - 1.5 <= from.z then
                            meet(math.min(from.z, at.z + 1.5))
                        end
                    end
                end
                if best == nil then return { hit = false } end
                return { hit = true, position = { x = from.x, y = from.y, z = best }, normal = { x = 0, y = 0, z = 1 },
                    material = 'simulated', distance = from.z - best }
            end or nil,
        },
        travel = {
            teleport = function(x, y, z, heading)
                player.teleports[#player.teleports + 1] = { x = x, y = y, z = z, heading = heading, at = W.now,
                    underFade = W.screenHeld(player),
                    animated = player.animatedUntil ~= nil and W.now < player.animatedUntil or nil }
                -- The game's own exit workspot holds the body (Staging,
                -- 2026-10-30, 22:46:23: eight placements, none held).
                if player.animatedUntil ~= nil and W.now < player.animatedUntil then return true end
                player.x, player.y, player.z = x, y, z
                -- THE AV'S COLLISION (1.8.1): a body put too near a hull's side is
                -- pushed out as it is put (`pushOut = { x, y }`, metres in the world;
                -- Staging, 2026-10-30: 0.34 m from open77_avexit 1.3.0's couch spot).
                local push = player.pushOut
                if push ~= nil then
                    player.x, player.y = player.x + (push.x or 0.0), player.y + (push.y or 0.0)
                end
                if heading ~= nil then player.yaw = heading end
                -- The body loses the ground for a moment and lands -- or, held by
                -- the forced freeze, stays off it until let go (`W.moved`).
                W.moved(player)
                -- Something turns the body back to a heading of its own after
                -- the next placements (`stickyYaw`).
                local sticky = player.stickyYaw
                if heading ~= nil and sticky ~= nil and (sticky.times or 0) > 0 then
                    sticky.times = sticky.times - 1
                    W.after(50, function()
                        player.yaw = sticky.yaw % 360.0
                        player.turnLog = player.turnLog or {}
                        player.turnLog[#player.turnLog + 1] = { why = 'sticky', yaw = player.yaw, at = W.now }
                    end)
                end
                return true
            end,
        },
        -- THE CLIENT STORE (`Open77.kvp`): this player's, by key -- values up to
        -- 64 KiB, 1 MiB in all (scripting/include/op77/Scripting/KvpStore.hpp).
        -- Every call reads the whole file, and a write writes it again, on the
        -- game's thread (scripting/src/KvpStore.cpp): each is logged in
        -- `player.kvpOps` `{ op, key, at }`, so a test can say when the store
        -- was touched.
        kvp = player.noKvp ~= true and {
            set = function(key, value)
                player.kvpOps = player.kvpOps or {}
                player.kvpOps[#player.kvpOps + 1] = { op = 'set', key = key, at = W.now }
                if type(key) ~= 'string' or key == '' or #key > 256 then return false, 'invalid_key' end
                if type(value) == 'string' and #value > 64 * 1024 then return false, 'value_too_large' end
                player.kvp = player.kvp or {}
                local total = 0
                for k, v in pairs(player.kvp) do
                    if k ~= key then total = total + #k + (type(v) == 'string' and #v or 8) end
                end
                if total + #key + (type(value) == 'string' and #value or 8) > 1024 * 1024 then
                    return false, 'byte_quota_exceeded'
                end
                player.kvp[key] = value
                return true
            end,
            get = function(key, default)
                player.kvpOps = player.kvpOps or {}
                player.kvpOps[#player.kvpOps + 1] = { op = 'get', key = key, at = W.now }
                local value = (player.kvp or {})[key]
                if value == nil then return default end
                return value
            end,
            keys = function(prefix, limit)
                player.kvpOps = player.kvpOps or {}
                player.kvpOps[#player.kvpOps + 1] = { op = 'keys', key = prefix, at = W.now }
                local out = {}
                for k in pairs(player.kvp or {}) do
                    if prefix == nil or k:sub(1, #prefix) == prefix then out[#out + 1] = k end
                end
                table.sort(out)
                while limit ~= nil and #out > limit do table.remove(out) end
                return out
            end,
            clear = function(prefix)
                player.kvpOps = player.kvpOps or {}
                player.kvpOps[#player.kvpOps + 1] = { op = 'clear', key = prefix, at = W.now }
                local removed = 0
                for k in pairs(player.kvp or {}) do
                    if prefix == nil or k:sub(1, #prefix) == prefix then
                        player.kvp[k] = nil
                        removed = removed + 1
                    end
                end
                return removed
            end,
        } or nil,
        screen = {
            -- A picture of this game's frame (`screen.capture`): `captureRefuse`
            -- a reason to refuse with, `captureBytes` its size (a JPEG of
            -- 30 KiB by default; one larger than `maxBytes` is
            -- `capture_too_large`). The picture says what the frame showed:
            -- covered by the fade, or not.
            capture = player.noCapture ~= true and function(options)
                if player.captureRefuse ~= nil then return nil, player.captureRefuse end
                options = options or {}
                local size = player.captureBytes or 30 * 1024
                local quality = tonumber(options.quality) or 85
                if player.captureShrinks then size = math.floor(size * quality / 85) end
                player.captures = player.captures or {}
                local entry = { at = W.now, covered = player.covered ~= nil, options = deepcopy(options) }
                player.captures[#player.captures + 1] = entry
                return { await = function()
                    if options.maxBytes ~= nil and size > options.maxBytes then return nil, 'capture_too_large' end
                    entry.bytes = size
                    return { bytes = ('\255\216' .. ('x'):rep(math.max(0, size - 2))), sizeBytes = size, width = 640,
                        height = 400, format = 'jpeg', copyMicros = 150, encodeMicros = 9000 }
                end }
            end or nil,
            fadeOut = function(options)
                if player.fadeRefused then return nil, 'transition_busy' end
                local id = handle('fade')
                player.fades[#player.fades + 1] = { id = id, out = true, at = W.now, options = deepcopy(options),
                    grounded = W.grounded(player) }
                player.covered = id
                player.coveredAt = W.now
                player.coveredMs = math.max(0, math.floor(tonumber(options ~= nil and options.durationMs) or 500))
                -- The screen black once the fade has run: the host's own local
                -- event, on every resource of this player's game.
                W.after(player.coveredMs, function()
                    -- `fadeNeverBlack`: a game whose fade never reports black.
                    if player.covered ~= id or player.fadeNeverBlack then return end
                    for _, other in pairs(W.vms) do
                        if other.side == 'client' and other.playerId == player.id and not other.dead then
                            other.fire('open77:screen:black', { id = id, faded = true })
                        end
                    end
                end)
                return id, { await = function() return true end }
            end,
            fadeIn = function(id, options)
                if player.covered ~= id then return false, 'not_owner' end
                local ms = math.max(0, math.floor(tonumber(options ~= nil and options.durationMs) or 500))
                player.fades[#player.fades + 1] = { id = id, out = false, at = W.now, options = deepcopy(options),
                    grounded = W.grounded(player) }
                player.covered = nil
                -- THE FADE'S HOLD ON THE BODY lasts until its fade-in has run.
                player.screenThawAt = W.now + ms
                W.after(ms, function() W.screenThaw(player) end)
                return true
            end,
            -- The game's own loading screen (`player.loading`, a suite's
            -- `{ active, kind, elapsedMs, progress }`); absent on a client
            -- without the read (`noLoadingState`).
            loadingState = player.noLoadingState ~= true and function()
                local state = type(player.loading) == 'table' and player.loading or {}
                return { active = state.active == true, id = tostring(state.id or '0'), revision = state.revision or 0,
                    kind = state.kind or 'unknown', progressKnown = state.progress ~= nil, progress = state.progress,
                    elapsedMs = state.elapsedMs or 0 }
            end or nil,
            -- The engine's own fade, whoever owns it.
            nativeState = function()
                local remaining = 0
                if player.covered == nil and player.screenThawAt ~= nil and W.now < player.screenThawAt then
                    remaining = player.screenThawAt - W.now
                end
                local black = player.covered ~= nil and W.now >= (player.coveredAt or 0) + (player.coveredMs or 0)
                return { faded = black, fading = player.covered ~= nil and not black, out = player.covered ~= nil,
                    busy = player.covered ~= nil or remaining > 0, ready = true, remainingMs = remaining }
            end,
        },
        sfx = {
            play = function(event, options)
                if player.refuseSfx then return nil, 'effects_backend_unavailable' end
                local id = handle('sfx')
                player.sfx[#player.sfx + 1] = { id = id, event = event, options = deepcopy(options), at = W.now }
                return id
            end,
            stop = function(id)
                player.sfx[#player.sfx + 1] = { id = id, stop = true, at = W.now }
                return true
            end,
        },
        vfx = {
            -- `W.vfxRefuse[effect] = reason` makes the platform refuse an effect
            -- (`not_found`: an archive this game does not have).
            play = function(effect, options)
                if W.vfxRefuse ~= nil and W.vfxRefuse[effect] ~= nil then return nil, W.vfxRefuse[effect] end
                local id = handle('vfx')
                player.vfx[id] = { effect = effect, position = deepcopy(options.position),
                    orientation = deepcopy(options.orientation), at = W.now, updates = 0 }
                player.vfxLog[#player.vfxLog + 1] = { op = 'play', id = id, effect = effect, at = W.now }
                return id
            end,
            update = function(id, options)
                if player.vfx[id] == nil then return false, 'unknown' end
                player.vfx[id].position = deepcopy(options.position)
                if options.orientation ~= nil then player.vfx[id].orientation = deepcopy(options.orientation) end
                player.vfx[id].updates = player.vfx[id].updates + 1
                return true
            end,
            stop = function(id)
                if player.vfx[id] ~= nil then
                    player.vfxLog[#player.vfxLog + 1] = { op = 'stop', id = id, effect = player.vfx[id].effect, at = W.now }
                end
                player.vfx[id] = nil
                return true
            end,
        },
        audio = {
            play3D = function(asset, position, options)
                if type(asset) ~= 'string' or not asset:match('^audio/av%-callout%-[%a%-]+%.%w+$') then
                    return nil, 'audio_asset_not_declared_or_unsafe'
                end
                local file = io.open(root .. '/' .. asset, 'rb')
                if file == nil then return nil, 'invalid_audio_asset' end
                file:close()
                local id = player.nextHandle + 1000
                player.nextHandle = player.nextHandle + 1
                player.audio[id] = { asset = asset, position = deepcopy(position), options = deepcopy(options),
                    volume = options.volume, at = W.now }
                return id
            end,
            setVolume = function(id, volume)
                if player.audio[id] == nil then return false, 'unknown' end
                player.audio[id].volume = volume
                return true
            end,
            setPosition = function(id, position)
                if player.audio[id] == nil then return false, 'unknown' end
                player.audio[id].position = deepcopy(position)
                return true
            end,
            destroy = function(id)
                if player.audio[id] == nil then return false, 'unknown' end
                player.audio[id] = nil
                return true
            end,
        },
        hud = {
            notify = function(text, options)
                player.notices[#player.notices + 1] = { text = text, options = deepcopy(options), at = W.now }
                return true
            end,
        },
        input = {
            -- `consume` (Stable 156): the bound native input suppressed while the
            -- mapping stands -- refused on a game that cannot (`noConsume`).
            -- `player.keyLog` keeps every registration and drop.
            registerKeyMapping = function(spec)
                player.keyLog = player.keyLog or {}
                if spec.consume == true and player.noConsume then
                    player.keyLog[#player.keyLog + 1] = { id = spec.id, on = false, refused = true, at = W.now }
                    return false, 'input_consumption_unavailable'
                end
                player.keys[spec.id] = deepcopy(spec)
                player.keys[spec.id].onPressed = spec.onPressed
                player.keyLog[#player.keyLog + 1] = { id = spec.id, on = true, consume = spec.consume == true, at = W.now }
                return spec.key
            end,
            unregisterKeyMapping = function(id)
                player.keyLog = player.keyLog or {}
                local had = player.keys[id] ~= nil
                player.keys[id] = nil
                player.keyLog[#player.keyLog + 1] = { id = id, on = false, at = W.now }
                return had
            end,
        },
        blips = {
            waypoint = function()
                if player.waypointBroken then return nil, 'waypoint_unavailable_on_this_host' end
                if player.waypoint == nil then return nil end
                return deepcopy(player.waypoint)
            end,
        },
        exports = {
            -- The interactions service, as far as the cards go.
            call = function(other, exportName, ...)
                if other ~= 'open77_interactions' then return nil, 'export_not_found' end
                local args = table.pack(...)
                local answer
                if exportName == 'create' then
                    local def = args[1]
                    local choice = type(def) == 'table' and type(def.choices) == 'table' and def.choices[1] or nil
                    if type(def) ~= 'table' or (def.entity == nil) == (def.position == nil) then
                        answer = { ok = false, error = 'invalid_target' }
                    elseif player.refuseEntityCards and def.entity ~= nil then
                        answer = { ok = false, error = 'invalid_entity' }
                    elseif type(def.distance) ~= 'number' or def.distance < 0.25 or def.distance > 25 then
                        answer = { ok = false, error = 'invalid_distance' }
                    elseif choice == nil or type(choice.key) ~= 'string' or not choice.key:match('^%u$')
                        or type(choice.event) ~= 'string' or not choice.event:match('^[%w_:%-%.]+$')
                        or #tostring(choice.label or '') > 96 then
                        answer = { ok = false, error = 'invalid_choice' }
                    else
                        local id = player.nextHandle + 5000
                        player.nextHandle = player.nextHandle + 1
                        player.cards[id] = deepcopy(def)
                        answer = { ok = true, handle = id }
                    end
                elseif exportName == 'remove' then
                    local had = player.cards[args[1]] ~= nil
                    player.cards[args[1]] = nil
                    answer = { ok = had }
                elseif exportName == 'clear' then
                    player.cards = {}
                    answer = { ok = true }
                else
                    return nil, 'export_not_found'
                end
                local promise = {}
                function promise:await()
                    env.Wait(0)
                    return answer
                end
                return promise
            end,
            -- open77_avexit's status (1.7.2): `player.animStatus` when a case
            -- sets it ('raise': open77_avexit not started), else no answer --
            -- as an older open77_avexit gives.
            callSync = function(other, exportName)
                if other == 'open77_avexit' and exportName == 'Status' and player.animStatus ~= nil then
                    W.statusAsks = (W.statusAsks or 0) + 1
                    if player.animStatus == 'raise' then error('export_resource_unavailable', 0) end
                    return deepcopy(player.animStatus)
                end
                return nil
            end,
        },
    }
    W.load(vm, root, files)
    return vm
end

--- The cards a player has up, as a list.
function W.cards(playerId)
    local out = {}
    for handle, def in pairs(W.players[playerId].cards) do
        local copy = deepcopy(def)
        copy.handle = handle
        out[#out + 1] = copy
    end
    return out
end

--- The player presses a key: the interactions service fires the choice of the
--- card that is active for them (inside its distance), as its owner's local
--- event. Answers whether a card took the press.
function W.press(playerId, pressedKey)
    local player = W.players[playerId]
    local vm = nil
    for _, candidate in pairs(W.vms) do
        if candidate.side == 'client' and candidate.playerId == playerId and candidate.resource == 'open77_avdoor' then
            vm = candidate
        end
    end
    if vm == nil then return false end
    for handle, def in pairs(player.cards) do
        local origin = nil
        if def.entity ~= nil then
            local vehicle = vehicleOfRef(def.entity)
            if vehicle ~= nil then origin = drawnAt(vehicle, player) end
        else
            origin = def.position
        end
        if origin ~= nil then
            local offset = def.offset or { x = 0, y = 0, z = 0 }
            local dx = player.x - (origin.x + offset.x)
            local dy = player.y - (origin.y + offset.y)
            local dz = player.z - (origin.z + offset.z)
            local choice = def.choices[1]
            if math.sqrt(dx * dx + dy * dy + dz * dz) <= def.distance and choice.key == pressedKey then
                vm.fire(choice.event, { owner = vm.resource, data = deepcopy(choice.data),
                    interactionId = def.id, choiceId = choice.id, handle = handle })
                W.run()
                return true
            end
        end
    end
    return false
end

--- A key bound with registerKeyMapping, pressed.
function W.pressMapped(playerId, mappingId)
    local spec = W.players[playerId].keys[mappingId]
    if spec == nil then return false end
    for _, vm in pairs(W.vms) do
        if vm.side == 'client' and vm.playerId == playerId then
            spawn(vm, spec.onPressed, mappingId)
            break
        end
    end
    W.run()
    return true
end

--- The exit package registered on the host (open77_avexit running): the
--- style and its five clips. Call before `W.server`.
function W.exitPackage()
    W.locomotion = { registered = { avexit = true }, assignments = {}, played = {},
        clips = { avexit = { enter = true, step = true, sit = true, step_m = true, couch = true } } }
end

--- A style another resource gave a player.
function W.styleFrom(playerId, owner, style)
    W.locomotion.registered[style] = true
    W.locomotion.assignments[playerId] = { style = style, owner = owner, revision = 900 }
end

--- Starts over: a fresh world for the next case.
function W.reset()
    for _, vm in pairs(W.vms) do vm.dead = true end
    W.vms, W.threads, W.queue, W.timers = {}, {}, {}, {}
    W.players, W.vehicles, W.logs, W.violations, W.threadErrors = {}, {}, {}, {}, {}
    W.sounds, W.netLog, W.warps, W.doorLog = {}, {}, {}, {}
    W.forcedExits, W.forcedExitMs = nil, nil
    W.invoker, W.resourceStates, W.groundAt, W.observerDown, W.groundAsks = nil, {}, nil, {}, 0
    W.terrainAt, W.rays, W.rayCount, W.legacyExitCamera, W.boundsSpace = nil, nil, 0, nil, nil
    W.locomotion, W.visibility, W.visibilityLog = nil, {}, {}
    W.vfxRefuse, W.selfGeometryAsks = nil, 0
    W.dropHello, W.droppedHellos, W.boneReads = nil, 0, 0
    W.lostToServer = nil
    W.holsters, W.statusAsks = 0, 0
    W.presented, W.dropEvents, W.droppedEvents = nil, nil, 0
    W.noPlayerLocks, W.lockCalls, W.gameEntries = nil, {}, {}
    W.authorityAsks = {}
    W.now = W.now + 3600000
end

return W
