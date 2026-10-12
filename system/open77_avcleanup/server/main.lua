-- =============================================================================
-- open77_avcleanup -- server
-- =============================================================================
--
-- A periodic world-sweep that removes AV records that are vacant, unleased and
-- have been sitting abandoned for a grace period. AVs spawn through the
-- freeroam menu and otherwise accumulate forever (nobody despawns them when
-- the pilot walks away), so this resource keeps the world from filling up
-- with empty Manticores/etc.
--
-- WHAT COUNTS AS "VACANT AND UNUSED" (all must hold):
--   1. The record is an AV: "Vehicle.av_*" or "Vehicle.max_tac_av".
--   2. Zero occupants (nobody is seated -- the snapshot carries `occupants`).
--   3. No physics lease (physicsOwner == 0 -- nobody is driving or was handed
--      the lease).
--   4. It has been in that state for at least `graceMinutes` (default 5 min,
--      i.e. it survived at least one full sweep). A player who just parked
--      their AV and stepped out is NOT removed on the first sweep; only an AV
--      nobody has touched for a full sweep cycle is reclaimed.
--
-- It does NOT touch: ground cars (not AV records), occupied vehicles, leased
-- vehicles, or any vehicle another resource currently holds. `vehicle.resource`
-- is read and logged on removal so it is visible in the log which owner
-- spawned it (e.g. freeroam) -- but the sweep never refuses based on owner:
-- the goal is a clean world, and the grace period is the guard that prevents
-- deleting a player's freshly-parked ride.
--
-- Interval: `intervalMinutes` (default 12, so the sweep lands every 10-15
-- minutes as requested). Tunable in the CONFIG block below; a reload picks it
-- up because the thread re-reads the config each cycle.
--
-- Observability: every removal is logged with id / record / position / owner
-- resource. `/avcleanup.now` forces an immediate sweep (admin); the periodic
-- thread is unaffected.
--
-- The decision logic lives in shared/sweep.lua (pure, unit-tested by
-- tests/sweep_test.lua); this file is the Open77 wiring only.
-- =============================================================================

local CONFIG = {
    -- How often the sweep runs. 10-15 minutes as requested; the thread adds a
    -- small jitter so a restart doesn't make every server sweep in lockstep.
    intervalMinutes = 12,
    jitterMinutes = 3,
    -- How long a vacant AV must stay vacant before it is reclaimed. Must be
    -- less than the interval so the "seen vacant once" pass graduates to
    -- "seen vacant twice" on the following sweep. 5 min < 12 min interval.
    graceMinutes = 5,
}

local function nowMinutes()
    return Open77.time.monotonic() / 60.0
end

-- id -> armedAtMinutes (only AVs seen vacant are tracked)
local vacantSince = {}

local function sweep(forced)
    local ok, all = pcall(Open77.vehicles.all)
    if not ok or type(all) ~= "table" then
        print("[open77_avcleanup] sweep failed: vehicles.all() unavailable")
        return
    end

    local removed, stillWithinGrace, removedInfo =
        AvCleanupSweep.runSweep(all, vacantSince, nowMinutes(), CONFIG.graceMinutes, forced,
            function(id)
                return pcall(Open77.vehicles.remove, id)
            end)

    -- One log line per removal, in sweep order (vacantFor = minutes armed).
    -- The module returns the exact age so this format matches the original
    -- resource output line-for-line.
    for _, info in ipairs(removedInfo) do
        local vehicle = info.vehicle
        print(string.format(
            "[open77_avcleanup] removed vacant AV id=%s record=%s pos=%.1f,%.1f,%.1f resource=%s vacantFor=%.1fmin",
            tostring(info.id), tostring(vehicle.record or ""),
            vehicle.x or 0, vehicle.y or 0, vehicle.z or 0,
            tostring(vehicle.resource or "?"), info.age))
    end

    print(string.format(
        "[open77_avcleanup] sweep %s: %d AV(s) removed, %d still within grace",
        forced and "(forced)" or "(periodic)", removed, stillWithinGrace))
end

-- Periodic sweep with jitter. Config is re-read each cycle so a reload or
-- config edit takes effect without restarting the resource.
CreateThread(function()
    while true do
        local interval = math.max(1, CONFIG.intervalMinutes) * 60
        local jitter = math.random(0, math.max(0, CONFIG.jitterMinutes)) * 60
        Wait((interval + jitter) * 1000)
        sweep(false)
    end
end)

-- Admin command: force an immediate sweep.
RegisterCommand("avcleanup.now", function(source, args, raw)
    sweep(true)
    if source ~= nil and source > 0 then
        TriggerClientEvent("chat:addMessage", source, {
            type = "system",
            author = "AVCLEANUP",
            text = "Forced AV cleanup sweep completed.",
            color = { 0, 229, 255 },
        })
    end
end, true) -- true = admin-gated

print("[open77_avcleanup] ready -- periodic AV cleanup every "
    .. CONFIG.intervalMinutes .. "-" .. (CONFIG.intervalMinutes + CONFIG.jitterMinutes)
    .. " min (grace " .. CONFIG.graceMinutes .. " min); /avcleanup.now")