-- =============================================================================
-- open77_reflex -- tests/idle_reads_test.lua
-- =============================================================================
-- The per-frame loop reads `Open77.reflex.state()` only while this client
-- holds a boost (the one branch that uses it), and still notices the primitive
-- releasing on its own. Everything the resource sends is recorded as a trace,
-- so an older source that read every frame can be checked for the same trace.
--
-- Standalone, from the resource directory:  lua tests/idle_reads_test.lua
-- REFLEX_SOURCE, when set, replaces client/main.lua; REFLEX_TRACE_ONLY skips
-- the read counts.
-- =============================================================================

local source = REFLEX_SOURCE
if source == nil then
    local file = assert(io.open("client/main.lua", "rb"), "run from the resource directory")
    source = file:read("a"); file:close()
end

local clock = 1000.0
local handlers, threads, trace, mappings = {}, {}, {}, {}
local reads = 0
local boost = nil -- { request = n, active = bool } while the primitive holds one
local function record(text) trace[#trace + 1] = text end

local INCARNATION = string.rep("ab", 16)
local ACTIVATION = string.rep("cd", 16)

Open77 = {
    time = { monotonic = function() return clock end },
    network = { status = function() return { phase = "active", playerId = 7 } end },
    character = { state = function()
        return { attached = true, alive = true, inWorkspot = false, vehicle = { mounted = false }, engineId = 99 }
    end },
    input = { isCaptured = function() return false end },
    reflex = {
        state = function()
            reads = reads + 1
            return boost and { active = boost.active, request = boost.request, phase = boost.active and "active" or "idle" }
                or { active = false, phase = "idle" }
        end,
        overdrive = function(tier, duration) record("overdrive:" .. tier .. ":" .. duration); boost = { request = 5, active = true }; return 5 end,
        clear = function() record("clear") end,
    },
    nameplates = { remove = function() end, set = function() return true end },
}
function RegisterKeyMapping(id, _, key, onPress) mappings[id] = onPress; record("mapping:" .. id .. ":" .. key); return true, key end
function TriggerServerEvent(name, data)
    local detail = type(data) == "table" and (data.phase or data.ok) or nil
    record("emit:" .. name .. (detail ~= nil and (":" .. tostring(detail)) or ""))
end
function RegisterNetEvent(name, callback) handlers[name] = callback end
function AddEventHandler(name, callback) handlers[name] = callback end
function exports() end
function GetCurrentResourceName() return "open77_reflex" end
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
    return REFLEX_TRACE_ONLY and expected or reads - before
end

assert(load(source, "@open77_reflex/client/main.lua", "t"))()
tick()
handlers["open77:reflex:projection"]({ player = 7, revision = 1, status = "pending", incarnation = INCARNATION,
    definition = { profile = "reflex_overdrive", config = { tier = "reflex", inputKey = "x", durationMs = 6000,
        presentation = "native" } } })

-- Projected, nothing held: the state is never read.
assert(readsDuring(10, 0) == 0, "idle frames read the reflex state")

-- Engaged and permitted: read every frame while the boost is held.
mappings.reflex_overdrive()
handlers["open77:reflex:permit"]({ incarnation = INCARNATION, revision = 1, sequence = 1, ok = true,
    activation = ACTIVATION, durationMs = 6000, tier = "reflex" })
assert(readsDuring(3, 3) == 3, "a held boost must be read every frame")

-- The primitive releases on its own: reported once, then idle again.
boost.active = false
assert(readsDuring(1, 1) == 1)
assert(readsDuring(10, 0) == 0, "frames after the release read the reflex state")

local expected = table.concat({
    "mapping:reflex_overdrive:X",
    "emit:open77:reflex:snapshot",
    "clear", "emit:open77:reflex:projectionResult:true",
    "emit:open77:reflex:intent",
    "overdrive:reflex:6000", "emit:open77:reflex:nativePhase:applied",
    "emit:open77:reflex:nativePhase:released",
}, "\n")
local actual = table.concat(trace, "\n")
assert(actual == expected, "trace changed:\n" .. actual)
io.write(REFLEX_TRACE_ONLY and ("open77_reflex: trace of %d sends OK (reads not checked)\n"):format(#trace)
    or ("open77_reflex: idle frames 0 reads, held boost 1 read each, trace of %d sends OK\n"):format(#trace))
