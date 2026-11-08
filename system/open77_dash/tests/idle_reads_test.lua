-- =============================================================================
-- open77_dash -- tests/idle_reads_test.lua
-- =============================================================================
-- The per-frame loop must not read `Open77.dash.call("activity")` while
-- nothing consumes it (no pending, running, binding or corrected dash), and
-- must read it every frame while something does. Everything the loop SENDS --
-- intents, phases, acks, natives other than the read -- is recorded as a trace
-- so a change to when the read happens can be compared against the previous
-- source for an identical trace.
--
-- Standalone, from the resource directory:  lua tests/idle_reads_test.lua
-- DASH_SOURCE, when set, is used instead of client/main.lua; with
-- DASH_TRACE_ONLY set the read counts are not asserted, which is how an older
-- source that read every frame is checked for the same trace.
-- =============================================================================

local source = DASH_SOURCE
if source == nil then
    local file = assert(io.open("client/main.lua", "rb"), "run from the resource directory")
    source = file:read("a"); file:close()
end

local clock = 1000.0
local keys = {}
local handlers, threads, trace = {}, {}, {}
local reads = 0
local sequence, phase, nativeActive, history = 0, "idle", false, {}
local function record(text) trace[#trace + 1] = text end

local INCARNATION = string.rep("ab", 16)
local ACTIVATION = string.rep("cd", 16)

Open77 = {
    time = { monotonic = function() return clock end },
    network = { status = function() return { phase = "active", playerId = 7, serverTimeMicroseconds = 0 } end },
    character = { state = function()
        return { attached = true, alive = true, inWorkspot = false, vehicle = { mounted = false },
            engineId = 99, forward = { x = 0, y = 1, z = 0 }, yaw = 0 }
    end },
    input = { isDown = function(key) return keys[key] == true end, isCaptured = function() return false end },
    camera = { view = function() return { forward = { x = 0, y = 1, z = 0 } } end },
    travel = { teleport = function() record("teleport"); return true end },
    dash = { call = function(operation, ...)
        if operation == "activity" then
            reads = reads + 1
            return { request = 42, sequence = sequence, phase = phase, mode = "ground", nativeActive = nativeActive,
                directionX = 0, directionY = 1, phaseSequence = #history, history = history }
        end
        record("native:" .. operation)
        if operation == "configure" then return 42 end
        if operation == "state" then return "ready", "" end
        if operation == "request" then sequence = sequence + 1; phase = "pending"; return sequence end
        return true
    end },
}
function TriggerServerEvent(name, data)
    local detail = type(data) == "table" and (data.phase or data.ok) or nil
    record("emit:" .. name .. (detail ~= nil and (":" .. tostring(detail)) or ""))
end
function RegisterNetEvent(name, callback) handlers[name] = callback end
function AddEventHandler(name, callback) handlers[name] = callback end
function exports() end
function GetCurrentResourceName() return "open77_dash" end
function CreateThread(callback) threads[#threads + 1] = coroutine.create(callback) end
function Wait() coroutine.yield() end
print = function() end

local function tick()
    clock = clock + 0.010
    for _, thread in ipairs(threads) do
        local ok, reason = coroutine.resume(thread)
        assert(ok, reason)
    end
end
local function readsDuring(frames, expected)
    local before = reads
    for _ = 1, frames do tick() end
    return DASH_TRACE_ONLY and expected or reads - before
end

assert(load(source, "@open77_dash/client/main.lua", "t"))()
tick() -- snapshot request; no projection yet
handlers["open77:dash:projection"]({ player = 7, revision = 1, status = "pending", incarnation = INCARNATION,
    definition = { profile = "dash", config = { inputKey = "shift", allowGround = true, allowAir = true,
        movementProfile = "native", presentation = "native", maxFallSpeed = 10 } } })
tick() -- configure, ready, ack

-- Idle: the native is never asked.
assert(readsDuring(10, 0) == 0, "idle frames read the dash activity")

-- A press: requested, read once to validate, intent sent; then read every
-- frame while the permit is pending.
keys.shift = true
assert(readsDuring(1, 1) == 1, "the press must read the activity exactly once")
assert(readsDuring(3, 3) == 3, "a pending dash must be read every frame")

-- Permitted: running, still read every frame, its phases forwarded.
handlers["open77:dash:permit"]({ incarnation = INCARNATION, revision = 1, sequence = sequence, ok = true,
    activation = ACTIVATION, expiresInMs = 500, directionX = 0, directionY = 1 })
phase, nativeActive = "active", true
history = { { sequence = sequence, phaseSequence = 1, phase = "started" } }
assert(readsDuring(2, 2) == 2, "a running dash must be read every frame")

-- Completed: the terminal phase is forwarded once and the loop is idle again.
phase, nativeActive = "completed", false
history[#history + 1] = { sequence = sequence, phaseSequence = 2, phase = "completed" }
assert(readsDuring(1, 1) == 1)
keys.shift = false
assert(readsDuring(10, 0) == 0, "frames after completion read the dash activity")

local expected = table.concat({
    "emit:open77:dash:snapshot",
    "native:release", "native:configure", "native:state", "emit:open77:dash:projectionResult:true",
    "native:request", "emit:open77:dash:intent",
    "native:approve",
    "emit:open77:dash:nativePhase:started", "emit:open77:dash:nativePhase:completed",
}, "\n")
local actual = table.concat(trace, "\n")
assert(actual == expected, "trace changed:\n" .. actual)
io.write(DASH_TRACE_ONLY and ("open77_dash: trace of %d sends OK (reads not checked)\n"):format(#trace)
    or ("open77_dash: idle frames 0 reads, busy frames 1 read each, trace of %d sends OK\n"):format(#trace))
