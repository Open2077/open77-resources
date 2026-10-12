-- =============================================================================
-- open77_avcleanup -- shared/sweep.lua
-- =============================================================================
-- The pure sweep logic for the vacant-AV cleanup, extracted from
-- server/main.lua so it is unit-testable (tests/sweep_test.lua) without any
-- Open77 runtime. This file makes NO Open77 calls and touches no globals other
-- than the module table -- it is a plain Lua 5.4 module.
--
-- The host (server/main.lua) owns the Open77 side: vehicles.all(), the remove
-- call, the periodic thread and the admin command. It feeds snapshots in here
-- and acts on the returned decisions.
--
-- Semantics (identical to the original inline logic):
--   * "AV record"      = "Vehicle.av_*" or "Vehicle.max_tac_av".
--   * "vacant"         = zero occupants AND no physics lease
--                        (physicsOwner == 0). A leased or occupied AV is never
--                        a candidate, not even on a forced sweep.
--   * grace            = an AV first seen vacant arms a timer; it is only
--                        removed once `now - armedAt >= graceMinutes` -- or
--                        immediately when the sweep is forced. A forced sweep
--                        still arms on first sight (the arm branch wins),
--                        matching the original code.
--   * vanished        = AVs tracked as vacant that are no longer returned by
--                        vehicles.all() are forgotten (despawned elsewhere).
-- =============================================================================

AvCleanupSweep = {}

-- Returns true when `record` is an AV record string.
function AvCleanupSweep.isAvRecord(record)
    if type(record) ~= "string" then
        return false
    end
    return record:sub(1, 11) == "Vehicle.av_" or record == "Vehicle.max_tac_av"
end

-- Returns true when a vehicle snapshot is vacant: nobody seated and no lease.
function AvCleanupSweep.isVacant(vehicle)
    local occupants = vehicle.occupants or {}
    local leased = (vehicle.physicsOwner or 0) ~= 0
    return #occupants == 0 and not leased
end

-- One step of the grace state machine.
--   since:  armedAt in minutes, or nil if this AV has never been seen vacant
--   now:    current monotonic time in minutes
--   grace:  grace period in minutes
--   forced: true when the sweep is an admin-forced sweep
-- Returns "watch" (arm the timer), "within-grace" (keep watching) or
-- "remove" (past grace, or forced on an already-armed AV).
function AvCleanupSweep.step(since, now, grace, forced)
    if since == nil then
        return "watch"
    end
    if forced or (now - since) >= grace then
        return "remove"
    end
    return "within-grace"
end

-- Runs one full sweep over a snapshot list (as returned by vehicles.all()).
--   vehicles:   list of vehicle snapshots
--   state:      mutable id -> armedAtMinutes map (owned by the caller)
--   now:        current monotonic time in minutes
--   grace:      grace period in minutes
--   forced:     admin-forced sweep flag
--   removeFn:   function(id, vehicle) -> boolean; the host's removal call
-- Returns (removed, stillWithinGrace, removedInfo) where removedInfo is a
-- list of { id, vehicle, age } for logging (vacantFor = age minutes).
function AvCleanupSweep.runSweep(vehicles, state, now, grace, forced, removeFn)
    local removed, stillWithinGrace = 0, 0
    local removedInfo = {}
    local seen = {}

    for _, vehicle in ipairs(vehicles) do
        local record = vehicle.record or ""
        if AvCleanupSweep.isAvRecord(record) then
            local id = vehicle.id
            seen[id] = true

            if AvCleanupSweep.isVacant(vehicle) then
                local action = AvCleanupSweep.step(state[id], now, grace, forced)
                if action == "watch" then
                    state[id] = now -- first sweep seeing it vacant
                elseif action == "remove" then
                    local okRemove = removeFn and removeFn(id, vehicle)
                    if okRemove then
                        removed = removed + 1
                        removedInfo[#removedInfo + 1] = {
                            id = id,
                            vehicle = vehicle,
                            age = now - state[id],
                        }
                    end
                    state[id] = nil -- cleared even when the removal call fails
                else -- "within-grace"
                    stillWithinGrace = stillWithinGrace + 1
                end
            else
                state[id] = nil -- occupied or leased: not a candidate
            end
        end
    end

    -- Forget AVs that no longer exist (despawned/removed elsewhere).
    for id in pairs(state) do
        if not seen[id] then
            state[id] = nil
        end
    end

    return removed, stillWithinGrace, removedInfo
end