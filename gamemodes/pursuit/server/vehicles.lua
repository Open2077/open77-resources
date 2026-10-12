-- Pursuit -- the cars a match owns.
--
-- Phase E, item 1. The state machine is unchanged: roles, win conditions and
-- resolution vocabulary are identical in a car and on foot. Only the distance
-- column changes (Config.match.vehicle) and two authoritative entities appear.
--
-- ------------------------------------------------------------------------
-- THE ONE THING TO UNDERSTAND BEFORE READING FURTHER
-- ------------------------------------------------------------------------
--
-- This file spawns cars. It does NOT seat anybody, and it cannot.
--
-- wiki/vehicles.md, "Server API": the seat ledger "is produced by native mount
-- detection and validated by the server", and "scripts cannot write this ledger
-- directly". There is no server-side seat call in the 47-method server surface
-- -- the closest thing in the whole API is `warpPlayerIntoVehicle`, which is a
-- CLIENT function, requires `vehicles.presentation`, "operate[s] only on remote
-- player proxies", returns `occupancy_mismatch` "unless the replicated server
-- ledger already contains that exact tuple", and is documented as unable to
-- "move the local player". Every one of those clauses independently rules it
-- out as a way to put a player in a car.
--
-- So the contract implemented here is "your car is on your mark, get in":
--
--   1. at countdown, create each side's car beside its driver's spawn mark;
--   2. republish the transform once the world around it has streamed in;
--   3. poll `Open77.vehicles.get(id).occupants` and tell the player, on a
--      timer, that his car is waiting;
--   4. confirm out loud the moment the ledger says he is aboard;
--   5. remove both cars when the match ends, however it ends.
--
-- Step 3 is a reminder, not enforcement. A player who refuses to get in plays a
-- vehicle-tuned match on foot and will lose it, which is a fair outcome and not
-- a bug. What WOULD be a bug is a leaked authoritative vehicle, and that is why
-- there are three independent cleanup paths below rather than one.

local Config = PursuitConfig

local function log(text) Pursuit.log(text) end
local function nowMs() return Pursuit.nowMs() end

-- matchId -> { [role] = { id, record, playerId, seatedAtMs, usableFromMs, ... },
--              createdAtMs }
--
-- `createdAtMs` is when the CAR appeared; `usableFromMs` is when its driver
-- could first act on it. They are 25-30 s apart on this build and confusing
-- them is what made the boarding affordance expire mid-approach.
local fleets = {}

-- ------------------------------------------------------------------ safety --

-- Every vehicle call goes through here.
--
-- Two failure shapes have to be survivable at once. A missing `world.vehicles`
-- permission may surface as a nil table, as a raised error, or as a
-- `nil, reason` return depending on where the check sits, and none of those may
-- take down the tick thread or the countdown -- a match that cannot have cars
-- must still be playable on foot. So: pcall, and normalise everything to
-- `value, reason`.
local function safeVehicleCall(name, ...)
    local api = Open77 and Open77.vehicles
    if type(api) ~= "table" or type(api[name]) ~= "function" then
        return nil, "vehicles_api_unavailable:" .. name
    end
    local ok, result, reason = pcall(api[name], ...)
    if not ok then return nil, tostring(result) end
    if result == nil then return nil, reason or "rejected" end
    return result, reason
end

local function flagsFor(spec)
    local flags = Open77 and Open77.vehicles and Open77.vehicles.flags
    if type(flags) ~= "table" then return nil end
    local mask = 0
    -- The engine bit. IT IS NOT WHY CARS DRIVE, and this comment used to claim
    -- the opposite -- loudly, and wrongly.
    --
    -- The belief was that a match car arrived un-started, and that this was why
    -- the throttle produced "0.57 m of roll then a stall, speedometer at 0".
    -- A/B-ed in game 2026-08-26, same mark, same car, same 5 s throttle:
    -- flag on -> 86.4 m, flag off -> 82.9 m. REDengine does not keep the engine
    -- running on an unoccupied vehicle anyway (`vehicle.status` reads
    -- `engine=off` on a car created with the bit set, `engine=on` the instant a
    -- player mounts it, because the mount sequence starts it), so the bit never
    -- survives to the entity while it would matter.
    --
    -- The real causes of the stall were a spawn yaw pointing the car at a
    -- pillar 2.7 m away, and throttle measured during the mount animation --
    -- see `Config.vehicles.spawns` and the E3 note in
    -- scripts/scenarios/pursuit-v1-duo.md.
    --
    -- Kept because the CANONICAL flag is what an observer's client reads for
    -- remote engine audio, and a match car is meant to be running. Behind a
    -- switch because that is what made the A/B possible without editing code.
    if Config.vehicles.engineOnAtSpawn ~= false then
        mask = mask | (flags.engineOn or 0)
    end

    if spec.lightsOn then mask = mask | (flags.lightsOn or 0) end
    if spec.sirenOn then mask = mask | (flags.sirenOn or 0) end
    -- Deliberately NOT `locked`. A locked car is a car nobody can get into, and
    -- getting into it is the only step of the whole sequence the server cannot
    -- perform on the player's behalf.
    if mask == 0 then return nil end
    return mask
end

-- ------------------------------------------------------------------- marks --

-- The offset a mark's car actually uses: the shared one, field-by-field
-- overridden by the mark's own `vehicleOffset`.
--
-- A partial override is MERGED rather than replacing the table, so a mark that
-- only needs to put its car on the other side says `lateral = -3.5` and
-- inherits the rest. Factored out of `markFor` because the start-up geometry
-- assertion below has to reason about exactly the same number, and re-deriving
-- it there is how two code paths drift apart -- which this file has already
-- paid for once with the spawn-pair selector.
function Pursuit.vehicleOffsetFor(point)
    local shared = Config.vehicles.spawnOffset
    local override = point ~= nil and point.vehicleOffset or nil
    if type(override) ~= "table" then return shared end
    return {
        forward = override.forward or shared.forward,
        lateral = override.lateral or shared.lateral,
        up = override.up or shared.up,
    }
end

-- Where a role's car goes: its driver's spawn mark, offset in the MARK's own
-- frame. Lateral by default, so the player does not spawn inside the car and
-- does not have to walk around it -- he turns and it is beside him.
--
-- `match.spawn` is the ONE pair the match runs on, chosen by
-- server/match.lua pickSpawnPair and already used to place the drivers.
-- `match.vehicleSpawn` survives only as an override hook for a future test
-- affordance; nothing sets it today, and anything that does is claiming the
-- cars belong somewhere the players are not.
local function markFor(match, role)
    local pair = match.vehicleSpawn or match.spawn
    if pair == nil then return nil end
    local point = pair[role]
    if point == nil or point.position == nil then return nil end

    local heading = point.heading or 0.0
    local forward = Pursuit.forwardFromHeading(heading)
    local right = Pursuit.rightFromHeading(heading)

    -- The offset is PER MARK, falling back to the shared one.
    --
    -- A single global offset cannot be right, because "beside the player" is a
    -- fact about the mark, not about the mode. Both C1 marks face the same
    -- heading, so they share a world "right" -- and measured in game on
    -- 2026-08-26 that direction is open road at the cop mark and a covered
    -- arcade at the runner mark, 58 m away. The cop's car spawned pristine on
    -- tarmac and was driven off; the runner's spawned into a pillar, came out
    -- nose-up with every window shattered, and could not be reached.
    --
    -- One number cannot describe both, so each mark may carry its own and the
    -- shared value stays the default. A partial override is merged field by
    -- field rather than replacing the table, so a mark that only needs to put
    -- its car on the other side says `lateral = -3.5` and inherits the rest.
    local offset = Pursuit.vehicleOffsetFor(point)

    -- Two ways to choose the car's height, and they are not equals.
    --
    -- A mark that carries `vehicleRestZ` -- the z a SETTLED car measured at
    -- this exact spot -- gets its car AT that height plus a small clearance,
    -- standing on its wheels from the first frame. A mark without it falls
    -- back to `read z + up`, which is safe and HOVERS: an unoccupied vehicle
    -- is physics-asleep and nothing lowers it until a driver wakes it. The
    -- long note above `restClearanceMetres` in shared/config.lua is the
    -- measurement; the fallback keeps the anti-clip guarantee for any mark
    -- nobody has measured a settled car on.
    local restZ = point.vehicleRestZ
    local carZ = restZ ~= nil
        and (restZ + (Config.vehicles.restClearanceMetres or 0.10))
        or (point.position.z + offset.up)

    return {
        position = {
            x = point.position.x + forward.x * offset.forward + right.x * offset.lateral,
            y = point.position.y + forward.y * offset.forward + right.y * offset.lateral,
            z = carZ,
        },
        -- Threaded through so the settle probe can tell "asleep at a surveyed
        -- rest height" from "asleep at a guessed hover" -- the two read
        -- identically (resting == commanded) and mean opposite things.
        restZ = restZ,
        -- The car faces the way its driver faces -- UNLESS the mark says
        -- otherwise. For the cop that default is the runner and it is proven
        -- (57 m driven straight off the mark). For the runner it was measured
        -- WRONG on 2026-08-26: the mark's forward is a traffic-light pillar
        -- 2.7 m from the car's nose, so the throttle produced 2.6 m of travel
        -- and a dead stop -- indistinguishable, from the driver's seat, from a
        -- car that will not start. Its open road is the OTHER way (38.3 m
        -- driven in 3 s, measured, reversing off that same pillar).
        --
        -- Hence `vehicleYaw`: an absolute per-mark heading for the CAR only.
        -- It deliberately does not move the car -- the position is surveyed and
        -- spawns pristine -- and it deliberately does not touch the player's
        -- own facing, which is `Config.match.spawns`/`vehicles.spawns` heading
        -- and belongs to the placement code, not to this file.
        yaw = point.vehicleYaw or heading,
    }
end

-- ------------------------------------------------------------------- doors --
--
-- Everything below this banner exists because of one measured fact: the
-- engine's entry prompt ("F Monter") answers within roughly ONE METRE of the
-- driver door and nowhere else. At the bonnet, at the boot, or on the passenger
-- flank there is no prompt, no refusal and no message of any kind, so a player
-- standing beside his own car has no way to tell "I am in the wrong place" from
-- "this car is broken". Two full match cycles were lost to that on 2026-08-26
-- by a tester who knew the mode.
--
-- Night City is left-hand drive -- `seat_front_left` is the only driver seat
-- (wiki/vehicles.md) -- so the driver door is the car's LEFT flank.

-- The driver door in world space.
--
-- `snapshot` is the live server snapshot when there is one, so the readout
-- follows a car that settled somewhere other than its mark. Its ORIENTATION is
-- not available: wiki/vehicles.md, "Server snapshot fields", exposes position
-- but no yaw, and says so explicitly. The commanded yaw from `markFor` is used
-- instead, which is exact for an unoccupied car that has just been re-planted
-- and is a good approximation for anything short of a car that has been pushed
-- and spun. Once a player is aboard nothing here is consulted at all.
local function doorPosition(car, snapshot)
    if car == nil or car.mark == nil then return nil end
    local base = car.mark.position
    if snapshot ~= nil and type(snapshot.x) == "number" then
        base = { x = snapshot.x, y = snapshot.y, z = snapshot.z }
    end
    if base == nil then return nil end

    local door = Config.vehicles.door or {}
    local lateral = door.lateral or 0.95
    local ahead = door.forward or 0.35
    local yaw = car.mark.yaw or 0.0
    local forward = Pursuit.forwardFromHeading(yaw)
    local right = Pursuit.rightFromHeading(yaw)
    -- MINUS right: the driver door is the LEFT flank.
    return {
        x = base.x + forward.x * ahead - right.x * lateral,
        y = base.y + forward.y * ahead - right.y * lateral,
        z = base.z,
    }
end

-- Does this mark put its own driver on the car's DRIVER side?
--
--   C - P = forward(markHeading)*offset.forward + right(markHeading)*offset.lateral
--   driver side  <=>  (C - P) . right(carYaw) > 0
--
-- i.e. the car's "right" points from the player towards the car, which puts the
-- player on its left. Checked against the one mark that is PROVEN to work -- the
-- C1 cop end, where a player boarded into `seat_front_left` on 2026-08-26 -- and
-- it agrees: `lateral = +3.5` with `carYaw == markHeading` gives a dot of +3.5.
--
-- Returns the dot product, so the caller can report how decisively a mark
-- passes or fails rather than just which way.
local function driverSideDot(point, carYaw)
    local offset = Pursuit.vehicleOffsetFor(point)
    local markForward = Pursuit.forwardFromHeading(point.heading or 0.0)
    local markRight = Pursuit.rightFromHeading(point.heading or 0.0)
    local carRight = Pursuit.rightFromHeading(carYaw)
    local dx = markForward.x * offset.forward + markRight.x * offset.lateral
    local dy = markForward.y * offset.forward + markRight.y * offset.lateral
    return dx * carRight.x + dy * carRight.y
end

-- ------------------------------------------------------------------ create --

local function createCar(match, role, spec)
    -- No driver, no car. A forced single-member match (`pursuit.force` with one
    -- player) has exactly one role filled, and spawning a driverless NCPD
    -- Cortes for the absent side would be an authoritative entity nobody asked
    -- for -- which is the precise thing this file must not leak.
    --
    -- Spelled out with `if`, not with `and`/`or`. The idiomatic one-liner
    --   local driverId = (role == "cop") and match.copId or match.runnerId
    -- is WRONG for exactly the case the guard below exists to catch: when the
    -- role is "cop" and `match.copId` is nil, the `and` yields nil and Lua
    -- falls through to the `or`, handing the cop's car to the RUNNER. Measured
    -- 2026-08-26 -- a `pursuit.force <one player>` match with only a runner
    -- spawned an NCPD Cortes anyway, driverless in every sense that matters,
    -- and the "no driver, no car" rule below never fired.
    local driverId
    if role == "cop" then driverId = match.copId else driverId = match.runnerId end
    if driverId == nil then
        log(("match %d: no %s in this match; no car created"):format(match.id, role))
        return nil
    end

    local mark = markFor(match, role)
    if mark == nil then
        log(("match %d: no %s mark to put a car on"):format(match.id, role))
        return nil
    end

    local definition = {
        record = spec.record,
        position = mark.position,
        yaw = mark.yaw,
        bucket = match.bucket,
        health = 1.0,
        flags = flagsFor(spec),
        primaryColor = spec.primaryColor,
        secondaryColor = spec.secondaryColor,
    }

    local id, reason = safeVehicleCall("create", definition)
    local record = spec.record

    -- The cop's record is the one model id in this mode that is not a
    -- `*_player` variant, because the catalogue contains no NCPD `*_player`
    -- record at all. If the liveried one is refused, fall back to the plain
    -- `*_player` chassis and SAY SO -- a match with an unliveried cop car is a
    -- playable match, and a silent fallback would hide the very fact the next
    -- session needs to record.
    if id == nil and spec.fallbackRecord ~= nil and spec.fallbackRecord ~= spec.record then
        log(("match %d: %s record '%s' refused (%s); retrying with '%s'"):format(
            match.id, role, tostring(spec.record), tostring(reason),
            tostring(spec.fallbackRecord)))
        definition.record = spec.fallbackRecord
        record = spec.fallbackRecord
        id, reason = safeVehicleCall("create", definition)
    end

    if id == nil then
        log(("match %d: %s car creation failed: %s"):format(
            match.id, role, tostring(reason)))
        return nil
    end

    log(("match %d: %s car %s (%s) at %.1f,%.1f,%.1f yaw %.0f bucket %d"):format(
        match.id, role, tostring(id), record,
        mark.position.x, mark.position.y, mark.position.z, mark.yaw, match.bucket))

    return {
        id = id,
        record = record,
        role = role,
        playerId = driverId,
        mark = mark,
        createdAtMs = nowMs(),
        replanted = false,
        seated = false,
        lastReminderMs = nil,
    }
end

-- ----------------------------------------------------------------- removal --

local function removeCar(car, why)
    if car == nil or car.id == nil then return false end
    local ok, reason = safeVehicleCall("remove", car.id)
    if not ok then
        log(("vehicle %s removal failed (%s): %s"):format(
            tostring(car.id), tostring(why), tostring(reason)))
        return false
    end
    return true
end

local function clearFleet(matchId, why)
    local fleet = fleets[matchId]
    if fleet == nil then return 0 end
    local removed = 0
    for _, role in ipairs({ "cop", "runner" }) do
        if fleet[role] ~= nil then
            if removeCar(fleet[role], why) then removed = removed + 1 end
            fleet[role] = nil
        end
    end
    fleets[matchId] = nil
    if removed > 0 then
        log(("match %d: %d car(s) removed (%s)"):format(matchId, removed, tostring(why)))
    end
    return removed
end

-- ---------------------------------------------------------------- electrics --

-- Re-assert the durable electrical bits (engine, headlights, siren) on a car
-- that already exists.
--
-- Needed because the server DELIBERATELY clears them at every authority
-- change. `VehicleAuthorityService.Revoke` and `.Park` both strip
-- `EngineOn | LightsOn | HighBeams | SirenOn` before publishing the new epoch,
-- "so parked vehicles do not retain engine audio or headlights on one client"
-- -- correct for a car somebody abandoned, wrong for an NCPD cruiser that is
-- meant to sit on its mark with the bar running. `setTransform` revokes the
-- lease by design (wiki/vehicles.md), so the re-plant below is itself one of
-- those authority changes: without this call the cop's livery goes dark at
-- exactly the moment the re-plant fires.
--
-- READ THIS BEFORE EXPECTING THE SIREN TO STAY ON. It will not, and the reason
-- is not here. See the note on `Config.vehicles.cop.sirenOn` and the report
-- that came with it: the client's durable owner report never carries the siren
-- bit back, so the server clears it again roughly five seconds after the car
-- streams in, whatever this function does. This call is correct, cheap and
-- event-driven -- one update per re-plant, not a poll -- and it becomes the
-- thing that makes the light bar stick the moment the client side is fixed.
local function reassertElectrical(match, role, car, spec)
    local mask = flagsFor(spec)
    if mask == nil or mask == 0 then return false end
    local current = safeVehicleCall("get", car.id)
    local flags = (type(current) == "table" and type(current.flags) == "number")
        and (current.flags | mask) or mask
    local ok, reason = safeVehicleCall("update", car.id, { flags = flags })
    if not ok then
        log(("match %d: %s car electrical re-assert failed: %s"):format(
            match.id, role, tostring(reason)))
    end
    return ok == true
end

-- -------------------------------------------------------------- re-planting --

-- Step 2, and the one step in this file that can destroy the thing it repairs.
--
-- `setTransform` is server-authoritative in the strongest sense the platform
-- has: wiki/vehicles.md says it "revokes an active physics lease, advances the
-- authority epoch, and publishes the complete canonical transform to every
-- current viewer". On a car standing empty in a half-streamed street that is
-- exactly the repair `Config.vehicles.replantAfterMs` describes. On a car with
-- a driver in it, it is a teleport plus an authority yank, and the solver
-- resolves the interpenetration it creates by throwing the car -- which is
-- what "la voiture spawn dans le sol et se retourne quand ça commence" is.
--
-- ------------------------------------------------------------------------
-- WHEN IT USED TO RUN, AND WHY THAT WAS THE BUG
-- ------------------------------------------------------------------------
--
-- The re-plant lived in the `tick` hook alone, gated on
-- `now - createdAtMs >= replantAfterMs` (4 s). But `server/match.lua` fires
-- `tick` ONLY for a match in state `active` -- its countdown branch pushes the
-- HUD and nothing else -- so that 4 s deadline could not be met until the
-- countdown had already ended. The re-plant therefore landed on the FIRST
-- ACTIVE TICK, at t+10 s, at the exact instant the match starts and with the
-- driver most likely already aboard. That is the precise opposite of the
-- claim on `replantAfterMs`, which says it "happens inside the countdown, so
-- nobody is driving when the ground is pulled back under the wheels".
--
-- Two changes, and both are needed:
--
--   * it is now SCHEDULED, by `SetTimeout` from the countdown hook, so it
--     really does fire `replantAfterMs` into the countdown -- 4 s, ahead of
--     the 5.7 s mean respawn fade, so no player can yet see the car, let
--     alone be sitting in it;
--   * it REFUSES to move an occupied car, whenever it runs. The tick keeps a
--     late fallback for a resource reloaded mid-countdown, and that fallback
--     is exactly as refused as the timer would be.
--
-- The guard is read from the ledger, not from `car.seated`: the cached flag is
-- up to `checkIntervalMs` old and the whole point of the guard is the case
-- where somebody boarded in the seconds nobody was looking.
local function replant(match, role, car, why)
    if car == nil or car.id == nil or car.replanted then return false end
    car.replanted = true

    local snapshot = safeVehicleCall("get", car.id)
    if type(snapshot) == "table" then
        car.snapshot = snapshot
        if type(snapshot.occupants) == "table" and #snapshot.occupants > 0 then
            log(("match %d: %s car re-plant SKIPPED (%s) -- somebody is aboard"):format(
                match.id, role, tostring(why)))
            return false
        end
        -- A car that has travelled is a car somebody drove, pushed or wrecked.
        -- Putting it back on its mark then is not a repair, it is a rewind.
        local dx = (snapshot.x or car.mark.position.x) - car.mark.position.x
        local dy = (snapshot.y or car.mark.position.y) - car.mark.position.y
        local drift = math.sqrt(dx * dx + dy * dy)
        if drift > (Config.vehicles.replantMaxDriftMetres or 6.0) then
            log(("match %d: %s car re-plant SKIPPED (%s) -- %.1f m off its mark already"):format(
                match.id, role, tostring(why), drift))
            return false
        end
    end

    local ok, reason = safeVehicleCall("setTransform", car.id, {
        position = car.mark.position,
        yaw = car.mark.yaw,
    })
    if not ok then
        log(("match %d: %s car re-plant failed (%s): %s"):format(
            match.id, role, tostring(why), tostring(reason)))
        return false
    end
    car.replantedAtMs = nowMs()
    reassertElectrical(match, role, car, Config.vehicles[role])
    return true
end

-- Did the car end up ON the ground, or IN it?
--
-- This is the only ground truth about spawn height the SERVER can obtain. It
-- cannot raycast -- there is no server-side ground query anywhere in the Lua
-- surface -- but `Open77.vehicles.get` does return the canonical position of a
-- car that has been simulated by a real client for a few seconds, and the
-- difference between that and the height we commanded is the settle.
--
-- What the numbers mean, and why this log line matters more than the fix
-- above:
--
--   settle ~= 0            the mark's z was already the surface. Nothing to do.
--   settle clearly NEGATIVE the car fell that far, so the commanded z was that
--                          much too high. Harmless up to a metre or so -- a
--                          car absorbs a kerb-height drop -- and it is the
--                          direction we deliberately chose to err in.
--   settle clearly POSITIVE the car was PUSHED UP, which only happens when the
--                          solver had to resolve an interpenetration. That is
--                          the flip, caught in a number, and it means
--                          `Config.vehicles.spawnOffset.up` is still too small
--                          for this mark.
--
-- Every authored z in `Config.vehicles.spawns` is a player- or NPC-position
-- read, and the one place this repository has compared such a read against the
-- real collision surface -- the lobby centre, whose ring drew half a metre
-- under the tarmac -- found the read roughly 0.5 m BELOW the surface. So the
-- offset needed here is not a matter of taste and it is not knowable from the
-- config: it has to be measured. This line is how the next session measures it,
-- per mark, without playing a match blind.
local function probeSettle(match, role, car)
    if car == nil or car.id == nil or car.mark == nil then return end
    local snapshot = safeVehicleCall("get", car.id)
    if type(snapshot) ~= "table" or type(snapshot.z) ~= "number" then
        log(("match %d: %s car settle unreadable"):format(match.id, role))
        return
    end
    car.snapshot = snapshot
    local settle = snapshot.z - car.mark.position.z
    local dx = (snapshot.x or 0) - car.mark.position.x
    local dy = (snapshot.y or 0) - car.mark.position.y
    local drift = math.sqrt(dx * dx + dy * dy)
    local verdict = "on the ground"
    if settle >= (Config.vehicles.settleRiseWarnMetres or 0.25) then
        verdict = "PUSHED UP -- the mark's z is BELOW the collision surface, raise spawnOffset.up"
    elseif settle <= -(Config.vehicles.settleDropWarnMetres or 1.5) then
        verdict = "a long drop -- spawnOffset.up is larger than this mark needs"
    elseif math.abs(settle) < 0.01 then
        -- The old wording called this "on the ground", and it was the lie
        -- that hid the hover bug for two days: resting == commanded to the
        -- centimetre does not mean the car settled here -- it means PHYSICS
        -- NEVER RAN. An unoccupied vehicle sleeps at the transform it was
        -- given until a driver wakes it (measured 2026-08-28: three matches,
        -- settle -0.00 on every car, wheels visibly in the air; production
        -- only ever logged non-zero settles one tick after "is aboard"). So
        -- say which of the two spawn heights it is sleeping at, which is the
        -- whole difference between fixed and floating.
        verdict = car.mark.restZ ~= nil
            and "asleep at its SURVEYED rest height -- on its wheels, will wake on boarding"
            or "asleep at spawn height -- physics never ran, HANGING at read z + up until someone boards"
    end
    log(("match %d: %s car settle %+.2f m (commanded z %.2f, resting z %.2f, drift %.2f m) -- %s"):format(
        match.id, role, settle, car.mark.position.z, snapshot.z, drift, verdict))
end

-- ---------------------------------------------------------------- boarding --

-- When could this driver FIRST have done anything about his car?
--
-- ------------------------------------------------------------------------
-- WHY THE ANCHOR IS NOT CAR CREATION
-- ------------------------------------------------------------------------
--
-- The boarding window used to be measured from `car.createdAtMs`, which is the
-- start of the countdown -- and the whole respawn fade sits inside it, before
-- the player can see or move. Measured with two clients on 2026-08-26 under a
-- fade of roughly 25-30 s: the affordance EXPIRED MID-APPROACH in three of four
-- attempts, the strip vanishing while the player was still walking to the door.
-- A window that opens on an event the player cannot perceive does not measure
-- his time to act; it measures the machine's.
--
-- Enlarging the constant was the obvious alternative and it is the wrong shape
-- of fix. The fade is not a constant: it is a kill, a respawn, a streaming
-- preload and a puppet attach, and its length moves with the machine, with how
-- many clients are running, and with what has to stream in.
--
-- ------------------------------------------------------------------------
-- HOW WIDELY IT MOVES -- AND WHAT THAT SAYS ABOUT THE TWO CONSTANTS
-- ------------------------------------------------------------------------
--
-- Read the numbers before trusting any of them. An earlier version of this
-- comment asserted that `match.spawnSettleMs` (8 s) and
-- `lobby.placementGraceMs` (15 s) were "BOTH two to four times short of what
-- was actually observed". That was generalised from the single bad session
-- above and it is false. Final verification on 2026-08-26 timed the fade eight
-- times across four matches, off the log line at the bottom of this section:
--
--     5.2  5.3  5.3  5.3  5.4  6.0  6.0  7.1     seconds, mean 5.7
--
-- Against that, both constants are OVER-estimates: 8 s is about 1.4x the mean
-- and 15 s about 2.6x. The 25-30 s reading is real but it is a worst case, not
-- the norm -- roughly five times the mean, from a loaded machine.
--
-- So the fade spans something like 5 s to 30 s, a six-fold spread, and the two
-- constants sit in the middle of it: comfortable against a typical fade,
-- hopeless against a bad one. They are not reliably too small, and correcting
-- them downward toward 5.7 s would only make the bad case worse. Neither
-- direction is available to a constant, and that -- not "the numbers are too
-- low" -- is the argument against writing a third one and hoping.
--
-- ------------------------------------------------------------------------
-- WHAT IS ACTUALLY OBSERVABLE FROM HERE
-- ------------------------------------------------------------------------
--
-- Four candidate anchors, and why this one:
--
--   * end of the fade -- not observable. The server is never told.
--   * the player's FIRST MOVEMENT -- rejected, and not narrowly. Post-placement
--     drift (plan section 7b) moves a placed player on his own for tens of
--     seconds, so "he moved" fires immediately and reliably for a player who
--     has done nothing at all. The anchor that sounds most like "usable time"
--     is the one this build cannot tell apart from noise.
--   * the countdown reaching zero (`match.startedAtMs`) -- exactly observable,
--     but it is just another fixed offset from the same unobserved event, and
--     the measurement says the fade routinely outlasts the entire 10 s
--     countdown. Wrong in the same direction, only less so.
--   * the player being genuinely PRESENT -- chosen.
--
-- "Present" is the conjunction of the two signals the rest of this resource
-- already treats as proof that a player is really where he was put:
--
--   1. `getLifeState().phase == "alive"` -- the respawn transaction completed.
--      `respawnpending`, `revivepending` and `dead` all mean it has not.
--   2. a replicated position inside THIS MATCH's bucket. A client that is not
--      incarnated sends no position snapshots at all (see the long note on
--      `pursuit.where` in server/main.lua), and one still reporting the lobby
--      bucket has not arrived in the match world yet.
--
-- Neither alone is enough: the phase can reach `alive` while the position is
-- still replicating the world he left, and a position can resolve mid-transfer
-- while the life authority still holds the transaction open.
--
-- Honest about what this is: the closest server-side PROXY for "the fade has
-- lifted", not a report from the client that it has. It can be early or late by
-- the gap between the server observing both signals and the player seeing his
-- screen -- an error far smaller than the fade itself at any of its observed
-- lengths, and, crucially, one that MOVES WITH the fade instead of assuming a
-- length for it. That is why the eight readings above did not require touching
-- this code: a design that tracks the quantity does not care that the quantity
-- turned out to be 5.7 s rather than 27 s.
--
-- Latched on first observation, so the window cannot restart if a later
-- snapshot goes unreadable. The log line IS the measurement: it prints the fade
-- length for every car of every match, so the number in this comment stops
-- being a one-off reading and becomes something the next session reads off --
-- which is exactly where the eight readings above came from. Read it again
-- before quoting any figure in this file; the spread is wide enough that one
-- session's number is not the truth.
local function usableSince(match, car, now)
    if car.usableFromMs ~= nil then return car.usableFromMs end
    if car.playerId == nil then return nil end

    local life = Open77.players.getLifeState(car.playerId)
    if life == nil or life.phase ~= "alive" then return nil end
    local position = Open77.players.position(car.playerId)
    if position == nil or position.bucket ~= match.bucket then return nil end

    car.usableFromMs = now
    log(("match %d: %s boarding window opens %.1fs after the car was created -- that gap IS the respawn fade, measured"):format(
        match.id, tostring(car.role), (now - (car.createdAtMs or now)) / 1000))
    return now
end

-- Is this car still inside the window in which "get in" is worth saying?
--
-- Two clocks, answering different questions:
--
--   * `affordanceSeconds` runs on the player's USABLE time, from the anchor
--     above. This is the one that decides when a player has had his chance.
--   * `affordanceCeilingSeconds` runs on wall clock from car creation,
--     unconditionally. It covers the one failure an anchored window has that a
--     wall-clock one does not: an anchor that never resolves would leave a
--     window that never starts and a hint that never leaves. With it, "a hint
--     cannot outlive the opening of a match" stays an absolute guarantee rather
--     than a conditional one.
--
-- Before the anchor resolves the answer is TRUE -- the window has not started,
-- so nothing has expired. That is what makes the strip wait out the fade
-- instead of dying behind it.
local function withinAffordanceWindow(match, car, now)
    local mount = Config.vehicles.mount or {}

    local ceiling = mount.affordanceCeilingSeconds
    if ceiling ~= nil and ceiling > 0 and
        (now - (car.createdAtMs or now)) >= (ceiling * 1000) then
        return false
    end

    local seconds = mount.affordanceSeconds
    if seconds == nil or seconds <= 0 then return true end

    local from = usableSince(match, car, now)
    if from == nil then return true end
    return (now - from) < (seconds * 1000)
end

-- Read the occupancy ledger for one car, throttled, and narrate the edges.
--
-- Extracted from the tick hook because the HUD readout below needs the same
-- answer, at the same 1 Hz, from a different caller -- and because the tick
-- hook does not run during the COUNTDOWN (match.lua only fires `tick` for an
-- active match), which is precisely the ten seconds in which a player is
-- supposed to be getting into his car. Without this the boarding strip would
-- appear only after the match had already started.
--
-- Returns the cached answer between polls, so calling it twice in a tick costs
-- one server read.
local function refreshSeat(match, role, car, now)
    if car == nil then return false end
    local mount = Config.vehicles.mount or {}
    if (now - (car.lastCheckMs or 0)) < (mount.checkIntervalMs or 1000) then
        return car.seated == true
    end
    car.lastCheckMs = now

    local snapshot = safeVehicleCall("get", car.id)
    -- Kept for the door readout, which follows a car that settled somewhere
    -- other than its mark.
    if type(snapshot) == "table" then car.snapshot = snapshot end

    local seated, seat = false, nil
    if type(snapshot) == "table" and type(snapshot.occupants) == "table" then
        for _, occupant in ipairs(snapshot.occupants) do
            -- Occupant ids can arrive as strings from the runtime, like every
            -- other id crossing that boundary. Compare as numbers or the ledger
            -- silently never matches.
            if tonumber(occupant.playerId) == car.playerId then
                seated = true
                seat = occupant.seat
            end
        end
    end

    if seated and not car.seated then
        car.seated = true
        car.seatedAtMs = now
        car.seat = seat
        log(("match %d: %s (player %s) is aboard vehicle %s in %s"):format(
            match.id, role, tostring(car.playerId), tostring(car.id), tostring(seat)))
    elseif not seated and car.seated then
        -- He got out, or was thrown out. Not an outcome -- the win conditions
        -- measure players, not cars -- but worth a line when a match ends in a
        -- way nobody expected.
        car.seated = false
        log(("match %d: %s left vehicle %s"):format(match.id, role, tostring(car.id)))
    end
    return seated
end

-- The HUD's boarding readout, for one player. `nil` means "draw nothing".
--
-- Installed for match.lua, which folds it into the per-player `matchState`
-- payload exactly as it already folds `Pursuit.scannerAgeMs`. Optional in the
-- same way: a payload without the key is a HUD with no boarding strip, so a
-- foot match, a match whose cars failed to create, and a server running an
-- older HUD all degrade to today's behaviour rather than to an error.
--
-- HOW IT GOES AWAY -- four independent conditions, any one of which removes the
-- strip from the screen within one HUD push (500 ms):
--
--   1. the player is ABOARD. The ledger says so; this returns nil.
--   2. the affordance window expired -- `mount.affordanceSeconds` of the
--      player's USABLE time (see `usableSince`), or `affordanceCeilingSeconds`
--      of wall clock whatever happens. The strip cannot outlive the opening of
--      a match even if the player never gets in.
--   3. the match left `countdown`/`active` -- resolved, or gone.
--   4. there is no car for this player at all.
--
-- Condition 2 is the load-bearing one, and it is also the one that was wrong
-- first time: without it "get in your car" is on screen for the five minutes of
-- chase it was supposed to help start, but anchored to car creation it expired
-- mid-approach in three attempts out of four. Both failures are the same
-- mistake -- a clock measuring the wrong thing -- in opposite directions.
function Pursuit.boardingFor(match, playerId, now)
    if match.mode ~= "vehicle" then return nil end
    if match.state ~= "countdown" and match.state ~= "active" then return nil end

    local fleet = fleets[match.id]
    if fleet == nil then return nil end

    local role = match.roles and match.roles[playerId] or nil
    local car = role ~= nil and fleet[role] or nil
    if car == nil or car.playerId ~= playerId then return nil end
    if not withinAffordanceWindow(match, car, now) then return nil end
    if refreshSeat(match, role, car, now) then return nil end

    local door = doorPosition(car, car.snapshot)
    local readout = { side = "left" }
    if door ~= nil then
        local position = Open77.players.position(playerId)
        -- Cross-bucket or unreadable: the strip still says WHERE the door is
        -- relative to the car, but omits a distance rather than sending a wrong
        -- one. Same discipline as `separation` and `scannerAgeMs`: an absent
        -- key is how the HUD is told "no data", and a stale number would read
        -- as fact.
        if position ~= nil and position.bucket == match.bucket then
            local dx = position.x - door.x
            local dy = position.y - door.y
            local dz = position.z - door.z
            readout.distance = math.sqrt(dx * dx + dy * dy + dz * dz)
            readout.inReach = readout.distance <=
                ((Config.vehicles.door or {}).promptRadius or 1.2)
        end
    end
    return readout
end

-- ------------------------------------------------------------------- hooks --

Pursuit.onMatch("countdown", function(match)
    if match.mode ~= "vehicle" then return end

    -- This file does NOT choose a spawn pair, and must not start doing so
    -- again. `server/match.lua pickSpawnPair` already made the choice -- it
    -- prefers `Config.vehicles.spawns` in vehicle mode -- and placed both
    -- players on it before this hook ran. The cars go on the SAME pair, read
    -- back off the match.
    --
    -- Choosing here as well is the bug this replaces: two selectors reading two
    -- tables put the players on the foot marks and the cars 470 m and 540 m
    -- away (offline, 2026-08-26, probe pair at 500 m). It was invisible only
    -- because `Config.vehicles.spawns` was nil.
    match.vehicleSpawn = nil
    if match.spawn == nil then
        log(("match %d: no spawn pair at all; no cars will be created"):format(match.id))
    elseif match.spawnSource == "vehicles.spawns" then
        log(("match %d: cars and players both on surveyed vehicle pair '%s'"):format(
            match.id, tostring(match.spawn.name)))
    else
        log(("match %d: no vehicle spawn pair configured; cars and players both on the FOOT marks '%s' -- see Config.vehicles.spawns"):format(
            match.id, tostring(match.spawn.name)))
    end

    local fleet = { createdAtMs = nowMs() }
    -- Resolved per player, not read straight from the config: `specFor` returns
    -- `Config.vehicles[role]` UNCHANGED when that player has no valid pick, so
    -- with nobody choosing this spawns exactly the pair it always did.
    fleet.runner = createCar(match, "runner", Pursuit.loadout.specFor("runner", match.runnerId))
    fleet.cop = createCar(match, "cop", Pursuit.loadout.specFor("cop", match.copId))
    fleets[match.id] = fleet
    match.cars = fleet

    -- Step 2 is scheduled HERE, not left to the tick.
    --
    -- `server/match.lua` fires the `tick` hook only for a match in state
    -- `active`, so a re-plant gated on the tick could not run until the
    -- countdown was over -- it landed at match start, on an occupied car, and
    -- that is the flip. See the long note above `replant`. A one-shot
    -- `SetTimeout` is the only way to get work done during a countdown from
    -- this file, and it puts the re-plant back where its own config comment
    -- always said it was: inside the countdown, before anybody can be aboard.
    --
    -- The settle probe follows it, far enough behind for the car to have come
    -- to rest and been simulated by a real client. It writes the one number
    -- nothing else in this mode can obtain: how far the ground actually was
    -- from the height we commanded.
    local matchId = match.id
    local replantAt = Config.vehicles.replantAfterMs or 0
    SetTimeout(replantAt, function()
        local live = fleets[matchId]
        if live == nil then return end
        for _, role in ipairs({ "cop", "runner" }) do
            replant(match, role, live[role], "countdown timer")
        end
    end)
    SetTimeout(replantAt + (Config.vehicles.settleProbeAfterMs or 4000), function()
        local live = fleets[matchId]
        if live == nil then return end
        for _, role in ipairs({ "cop", "runner" }) do
            probeSettle(match, role, live[role])
        end
    end)

    -- Tell him WHERE, not just THAT.
    --
    -- "Your vehicle is beside you. Get in." was the old line, and it is exactly
    -- as much help as the engine gives: none about the one thing that decides
    -- whether the prompt appears. Naming the driver's door and the distance to
    -- it turns "nothing is happening" into "I am two metres from the wrong
    -- corner of the car", which a player can act on.
    --
    -- The distance is from the SPAWN MARK, because at this instant the
    -- placement transaction is still in flight and the player has no readable
    -- position. It is a briefing, not a readout; the live readout is the HUD
    -- strip fed by `Pursuit.boardingFor`.
    for _, role in ipairs({ "cop", "runner" }) do
        local car = fleet[role]
        if car ~= nil and car.playerId ~= nil then
            local pair = match.spawn
            local point = pair ~= nil and pair[role] or nil
            local door = doorPosition(car, nil)
            local metres
            if point ~= nil and point.position ~= nil and door ~= nil then
                local dx = point.position.x - door.x
                local dy = point.position.y - door.y
                metres = math.sqrt(dx * dx + dy * dy)
            end
            Pursuit.notify(car.playerId, "info",
                metres ~= nil
                    and ("Your car is %.0f m away -- get in at the DRIVER'S DOOR, on its LEFT side."):format(metres)
                    or "Your car is beside you -- get in at the DRIVER'S DOOR, on its LEFT side.",
                6000)
        end
    end
end)

-- Republish the transform, then nag about the empty seat.
--
-- Both jobs are polls rather than events because the platform offers no server
-- event for "the world around this vehicle finished streaming", and because
-- `onVehicleOccupancyChanged` fires per revision on every vehicle rather than
-- per match. At the mode's own 5 Hz, throttled by `checkIntervalMs`, a poll is
-- cheaper to reason about than a global event filter.
Pursuit.onMatch("tick", function(match, now)
    local fleet = fleets[match.id]
    if fleet == nil then return end
    local mount = Config.vehicles.mount

    for _, role in ipairs({ "cop", "runner" }) do
        local car = fleet[role]
        if car ~= nil then
            -- Step 2, FALLBACK ONLY.
            --
            -- The re-plant is scheduled from the countdown hook now, because
            -- this hook does not run during a countdown at all -- which is
            -- exactly how the re-plant used to end up firing at match start,
            -- on a car with its driver already in it. See the note above
            -- `replant`.
            --
            -- Kept because a resource reloaded mid-countdown loses its pending
            -- `SetTimeout` and would otherwise never re-plant. `replant`
            -- refuses an occupied or already-moved car whichever path calls
            -- it, so the fallback cannot reintroduce the bug: at this point in
            -- a live match it will nearly always decline, and say so once.
            if not car.replanted and
                (now - car.createdAtMs) >= (Config.vehicles.replantAfterMs or 0) then
                replant(match, role, car, "tick fallback")
            end

            local seated = refreshSeat(match, role, car, now)

            -- Step 3: remind, on a timer, and only inside the boarding window.
            --
            -- The window is the whole point of the change. This used to fire
            -- every 10 s for as long as the match lasted, at a player who had
            -- already decided to run on foot -- five minutes of toasts during
            -- the part of the mode that most needs a clear screen. Boarding is
            -- a question for the opening of a match and noise afterwards, so it
            -- expires on its own whether or not anybody got in.
            if not seated and car.playerId ~= nil and match.state == "active" and
                withinAffordanceWindow(match, car, now) then
                -- The SAME anchor as the strip, not `createdAtMs`.
                -- Counted from creation, `remindAfterMs` fired its first
                -- toast five seconds into a fade that lasts twenty-five,
                -- so the one reminder most likely to be useful was the
                -- one guaranteed to be unseen. `usableSince` is nil until
                -- the player is present, which makes `since` zero and
                -- holds every toast back until he can read it.
                local from = usableSince(match, car, now)
                local since = (from ~= nil) and (now - from) or 0
                local last = car.lastReminderMs
                local due = (last == nil)
                    and (since >= (mount.remindAfterMs or 5000))
                    or (last ~= nil and (now - last) >= (mount.remindEveryMs or 10000))
                if due then
                    car.lastReminderMs = now
                    Pursuit.notify(car.playerId, "warning",
                        "Your car is waiting -- the DRIVER'S DOOR is on its LEFT side.", 4000)
                end
            end
        end
    end
end)

Pursuit.onMatch("resolved", function(match)
    clearFleet(match.id, "resolved")
    match.cars = nil
end)

-- A disconnect resolves the match, which clears the fleet through the hook
-- above -- but only if the match record still exists and the resolution runs to
-- completion. This handler is the second, independent path, and it is here
-- because "a leaked authoritative vehicle per match" is the exact failure this
-- feature must not have.
AddEventHandler("pursuit:playerGone", function(playerId)
    for matchId, fleet in pairs(fleets) do
        for _, role in ipairs({ "cop", "runner" }) do
            local car = fleet[role]
            if car ~= nil and car.playerId == playerId then
                log(("player %s disconnected; clearing match %d's cars"):format(
                    tostring(playerId), matchId))
                clearFleet(matchId, "disconnect")
                break
            end
        end
    end
end)

-- The third path: an orphan sweeper.
--
-- Belt and braces, and the braces are load-bearing. `fireHooks` pcalls each
-- hook, so a bug in the resolved handler above is survivable by design -- which
-- means it is also silently survivable, and a leaked car would just sit in a
-- released bucket forever. This catches that, and it catches the case where a
-- match record vanished by a route nobody anticipated.
--
-- Deliberately slow: the fleets table has one entry per live match, so once a
-- second would be pure waste.
-- The fourth path, and the only one that survives a reload.
--
-- The three above all reason from `fleets`, which is a RESOURCE LOCAL. A reload
-- replaces this VM, so `fleets` comes back empty while the vehicles it
-- described are still standing in the world -- server-owned, in a bucket
-- nobody will release, invisible to every sweeper that starts from the table.
-- Measured 2026-08-26: three hot reloads during one live match left
-- `pursuit.cars` answering "no match fleets" while `vehicle.list` still
-- counted two cars, one of them with a player sitting in it. A burning wreck
-- parked on a cop spawn mark, seen in an earlier session, is the same orphan
-- a few matches later.
--
-- The fix has to reason from the SERVER's ledger instead, which does survive:
-- `Open77.vehicles.all()` returns every live vehicle with the `resource` that
-- created it. Anything this resource owns and no fleet claims is a leak.
--
-- Two consecutive sightings, not one. `createCar` and the `fleets[match.id]`
-- assignment happen in the same non-yielding block, so a car cannot be
-- observed between the two today -- but that is a property of the countdown
-- hook, not a guarantee this file can enforce, and paying one extra sweep
-- interval is cheaper than deleting a car out from under a driver.
local unclaimedSince = {}

local function claimedIds()
    local claimed = {}
    for _, fleet in pairs(fleets) do
        for _, role in ipairs({ "cop", "runner" }) do
            local car = fleet[role]
            if car ~= nil and car.id ~= nil then claimed[car.id] = true end
        end
    end
    return claimed
end

-- The last census, so the line below is printed on CHANGE and not every 5 s.
local lastCensus = nil

local function reconcile(why)
    local all, allReason = safeVehicleCall("all")
    if type(all) ~= "table" then
        log(("vehicle reconciliation could not enumerate (%s): %s"):format(
            why, tostring(allReason)))
        return 0
    end
    local mine = GetCurrentResourceName()
    local claimed = claimedIds()
    local seen, removed = {}, 0

    -- The census, and it earns its place.
    --
    -- `Open77.vehicles.all()` returns an EMPTY TABLE both when the world holds
    -- no vehicles and when this resource may not enumerate them
    -- (`CanUseVehicles()` false, or the service unavailable) -- unlike `create`,
    -- which names its refusal. A reconciliation that silently found nothing is
    -- therefore indistinguishable from one that was silently forbidden, and on
    -- 2026-08-26 that ambiguity cost the first reading of this very bug. So the
    -- census is stated out loud, with the per-resource breakdown that tells
    -- "the ledger is empty" apart from "we cannot see it".
    local total, byResource = 0, {}
    for _, vehicle in ipairs(all) do
        total = total + 1
        local owner = tostring(vehicle.resource)
        byResource[owner] = (byResource[owner] or 0) + 1
    end
    local breakdown = {}
    for owner, count in pairs(byResource) do
        breakdown[#breakdown + 1] = ("%s=%d"):format(owner, count)
    end
    table.sort(breakdown)
    local census = ("%d [%s]"):format(total, table.concat(breakdown, " "))
    if census ~= lastCensus then
        lastCensus = census
        log(("vehicle census (%s): server ledger holds %s; this resource is '%s'"):format(
            why, census, tostring(mine)))
    end

    for _, vehicle in ipairs(all) do
        local id = vehicle.id
        if id ~= nil and vehicle.resource == mine and not claimed[id] then
            seen[id] = true
            -- The two-sightings rule is a SWEEP rule only. `start` and `stop`
            -- are both moments at which no match can exist in this VM, so there
            -- is nothing a grace period could protect and waiting five seconds
            -- would only mean five more seconds of wrecks on the marks -- or,
            -- at stop, the VM being gone before the second sighting ever came.
            if unclaimedSince[id] ~= nil or why ~= "sweep" then
                local ok, reason = safeVehicleCall("remove", id)
                if ok then
                    removed = removed + 1
                    log(("orphan vehicle %s (%s, bucket %s) removed -- owned by this resource, claimed by no fleet (%s)"):format(
                        tostring(id), tostring(vehicle.record), tostring(vehicle.bucket), why))
                else
                    log(("orphan vehicle %s removal failed: %s"):format(
                        tostring(id), tostring(reason)))
                end
                unclaimedSince[id] = nil
            else
                unclaimedSince[id] = nowMs()
            end
        end
    end
    for id in pairs(unclaimedSince) do
        if not seen[id] then unclaimedSince[id] = nil end
    end
    return removed
end

Pursuit.reconcileVehicles = reconcile

-- Hand the cars back BEFORE the VM is torn down.
--
-- The host already removes every vehicle a stopping resource owns
-- (`ServerResourceHost.Stop` -> `RemoveOwned`), and the server ledger really
-- does come back empty -- measured. What does NOT happen is the clients
-- despawning them: after three hot reloads during a live match, the server held
-- 0 vehicles and `vehicle.list` on both clients still counted the same 2, with
-- full replica records (owner, epoch, revision). They are ghosts: no server
-- ledger entry, no fleet, nobody to remove them, standing on the spawn marks
-- until the game is restarted -- and a later match spawns its cars INTO them,
-- which is where the broken glass and the detached parts on an allegedly
-- pristine NCPD Cortes came from, and almost certainly where the burning wreck
-- seen parked on a cop mark came from too.
--
-- Removing them here goes through the ordinary `Open77.vehicles.remove` path
-- instead, which is the one that demonstrably reaches the clients: every match
-- resolution in the same session removed its two cars cleanly. `Stop` emits
-- this event and then ticks once, so the calls are made while the API is still
-- live.
--
-- This does not repair the underlying client-side despawn gap -- see the
-- session notes; that one is C++ and wants its own investigation -- it removes
-- the only path that was actually reaching it.
AddEventHandler("onResourceStop", function(name)
    if name ~= GetCurrentResourceName() then return end
    local removed = 0
    for matchId in pairs(fleets) do
        removed = removed + clearFleet(matchId, "resource_stopping")
    end
    removed = removed + reconcile("stop")
    log(("vehicles handed back before stop -- %d removed through the normal path"):format(removed))
end)

CreateThread(function()
    while true do
        Wait(5000)
        for matchId in pairs(fleets) do
            if Pursuit.matches[matchId] == nil then
                log(("orphan fleet for match %d (no such match); sweeping"):format(matchId))
                clearFleet(matchId, "orphan")
            end
        end
        reconcile("sweep")
    end
end)

-- ---------------------------------------------------------------- readouts --

Pursuit.describe = Pursuit.describe or {}
Pursuit.describe.vehicles = function(match, now)
    if match.mode ~= "vehicle" then return "off (foot mode)" end
    local fleet = fleets[match.id]
    if fleet == nil then return "no fleet" end
    local parts = {}
    for _, role in ipairs({ "cop", "runner" }) do
        local car = fleet[role]
        if car == nil then
            parts[#parts + 1] = ("%s=NONE"):format(role)
        else
            -- The door distance is the number that explains a player standing
            -- next to his car saying nothing happens: the engine answers within
            -- ~1 m of the DRIVER door and nowhere else.
            local doorText = ""
            if match.state == "countdown" or match.state == "active" then
                local boarding = Pursuit.boardingFor(match, car.playerId, now)
                if boarding ~= nil then
                    doorText = (" door=%s%s"):format(
                        boarding.distance and ("%.1fm"):format(boarding.distance) or "unreadable",
                        boarding.inReach and " IN REACH" or "")
                elseif not car.seated then
                    doorText = " door=affordance-expired"
                end
            end
            -- `usable` is the anchor readout, and it is the fastest way to
            -- tell a boarding affordance that expired too early from one that
            -- never opened. `fade` is how long the respawn actually took for
            -- this player, on this run -- the measurement that used to have to
            -- be inferred from a stopwatch and a screenshot.
            local usableText
            if car.usableFromMs == nil then
                usableText = " usable=pending"
            else
                local budget = (Config.vehicles.mount or {}).affordanceSeconds or 0
                usableText = (" usable=fade%.1fs+%.1fs/%.0fs"):format(
                    (car.usableFromMs - (car.createdAtMs or car.usableFromMs)) / 1000,
                    (now - car.usableFromMs) / 1000, budget)
            end
            parts[#parts + 1] = ("%s=%s(%s) seated=%s%s replanted=%s%s%s"):format(
                role, tostring(car.id), (car.record:gsub("^Vehicle%.", "")),
                car.seated and "yes" or "no",
                car.seated and ("@" .. tostring(car.seat)) or "",
                car.replanted and "yes" or "no", usableText, doorText)
        end
    end
    return table.concat(parts, "  ")
end

-- ---------------------------------------------------------------- commands --

-- Dump what the server actually knows about a match's cars, and optionally put
-- them back on their marks.
--
-- The re-plant is the useful half. Post-placement drift is a known open issue
-- on this build -- a placed player can keep moving on his own for tens of
-- seconds -- so a car that ends up somewhere unhelpful is expected at least
-- some of the time, and re-planting it is faster than restarting the match.
RegisterCommand("pursuit.cars", function(source, args, raw)
    -- Not named `replant`: that is a file-scope function now, and shadowing it
    -- inside the one command whose job is to re-plant is how a later edit ends
    -- up calling a boolean.
    local wantReplant = (args and args[1] ~= nil and tostring(args[1]):lower() == "replant")
    local reported = 0
    for matchId, fleet in pairs(fleets) do
        local match = Pursuit.matches[matchId]
        reported = reported + 1
        Pursuit.output(source, raw, true,
            ("match %d [%s] mode=%s"):format(matchId,
                match and tostring(match.state) or "gone",
                match and tostring(match.mode) or "?"))
        for _, role in ipairs({ "cop", "runner" }) do
            local car = fleet[role]
            if car == nil then
                Pursuit.output(source, raw, true, ("  %s: no car"):format(role))
            else
                local snapshot = safeVehicleCall("get", car.id)
                local seats = {}
                if type(snapshot) == "table" and type(snapshot.occupants) == "table" then
                    for _, occupant in ipairs(snapshot.occupants) do
                        seats[#seats + 1] = ("%s@%s"):format(
                            tostring(occupant.playerId), tostring(occupant.seat))
                    end
                end
                -- `flags` is the canonical state mask, and printing it is the
                -- only way to tell "the server never set the bit" from "the
                -- server set it and the entity ignored it". Those two look
                -- identical from inside the car and cost a session to separate
                -- once already.
                Pursuit.output(source, raw, true,
                    ("  %s: id=%s record=%s driver=%s bucket=%s pos=%s yaw=%.0f occupants=[%s] health=%s flags=0x%X"):format(
                        role, tostring(car.id), car.record, tostring(car.playerId),
                        snapshot and tostring(snapshot.bucket) or "?",
                        snapshot and ("%.1f,%.1f,%.1f"):format(
                            snapshot.x or 0, snapshot.y or 0, snapshot.z or 0) or "?",
                        car.mark and car.mark.yaw or 0.0,
                        table.concat(seats, " "),
                        snapshot and tostring(snapshot.health) or "?",
                        (snapshot and snapshot.flags) or 0))
                -- Deliberately NOT routed through `replant`, and deliberately
                -- not guarded. That function refuses an occupied or moved car
                -- because it fires on a timer at a moment nobody asked for;
                -- this one only runs because an operator typed the word, and
                -- "put it back on the mark even though I am sitting in it" is
                -- the entire point of typing it. `replant`'s one-shot latch is
                -- also bypassed, so this stays usable more than once.
                if wantReplant then
                    local ok, reason = safeVehicleCall("setTransform", car.id, {
                        position = car.mark.position,
                        yaw = car.mark.yaw,
                    })
                    -- setTransform revokes the lease, and a revoke clears the
                    -- electrical bits server-side; put them back or an
                    -- operator re-planting the cop's car turns its lights off.
                    if ok == true and match ~= nil then
                        reassertElectrical(match, role, car, Config.vehicles[role])
                    end
                    Pursuit.output(source, raw, ok == true,
                        ("  %s: re-plant %s"):format(role,
                            ok == true and "ok" or ("failed: " .. tostring(reason))))
                end
            end
        end
    end
    if reported == 0 then
        Pursuit.output(source, raw, false,
            "no match fleets; usage: pursuit.cars [replant]")
    end
end, false)

-- ------------------------------------------------------- geometry assertion --

-- Prove, without playing a match, that every authored mark puts its driver on
-- the side of the car that has a door he can use.
--
-- This exists because the failure it catches is SILENT in every other channel.
-- A mark with the wrong sign spawns a pristine car on good ground, logs a
-- successful creation, reports `rendered`/`health 1.0`, and then simply never
-- offers a prompt -- and the player, standing a metre from a flank with no
-- door, has no way to tell that from a broken car. It cost two full match
-- cycles on 2026-08-26, and it was true of the C1 runner mark for as long as
-- that mark existed.
--
-- Both tables are swept, and each mark is named with the table it came from --
-- the same lesson `server/bounds.lua` learned when its arena sweep read only
-- `Config.match.spawns` and never checked a pair added to `Config.vehicles`.
--
-- It reports and does not enforce. A badly authored mark should produce a loud
-- line and a playable match, not a refusal to create a car.
local function assertSpawnGeometry()
    local tables = {
        { name = "vehicles.spawns", pairs = Config.vehicles and Config.vehicles.spawns },
        { name = "match.spawns", pairs = Config.match and Config.match.spawns },
    }
    local checked, bad = 0, 0
    for _, entry in ipairs(tables) do
        if type(entry.pairs) == "table" then
            for _, pair in ipairs(entry.pairs) do
                for _, role in ipairs({ "cop", "runner" }) do
                    local point = pair[role]
                    if type(point) == "table" and point.position ~= nil then
                        checked = checked + 1
                        local carYaw = point.vehicleYaw or point.heading or 0.0
                        local dot = driverSideDot(point, carYaw)
                        -- Distance from the mark to the door, which is the
                        -- number that decides whether the prompt is already
                        -- there when the fade lifts (~1 m) or whether the
                        -- player has to find it.
                        local fakeCar = { mark = markFor({ spawn = pair }, role) }
                        local metres
                        if fakeCar.mark ~= nil then
                            local door = doorPosition(fakeCar, nil)
                            if door ~= nil then
                                local dx = point.position.x - door.x
                                local dy = point.position.y - door.y
                                metres = math.sqrt(dx * dx + dy * dy)
                            end
                        end
                        local where = ("%s/%s '%s'"):format(
                            entry.name, role, tostring(pair.name))
                        if dot > 0 then
                            log(("spawn geometry OK -- %s: driver's side, door %s from the mark"):format(
                                where, metres and ("%.1f m"):format(metres) or "unknown"))
                        else
                            bad = bad + 1
                            log(("spawn geometry WARNING -- %s: the player lands on the PASSENGER side (dot=%.2f). " ..
                                 "The engine only offers 'F Monter' within ~1 m of the DRIVER door, so he will " ..
                                 "see no prompt and no message at all. Fix: flip the sign of this mark's " ..
                                 "vehicleOffset.lateral, or add/remove a 180-degree vehicleYaw."):format(
                                where, dot))
                        end
                    end
                end
            end
        end
    end
    log(("spawn geometry: %d mark(s) checked, %d on the wrong side"):format(checked, bad))
end

AddEventHandler("onResourceStart", function(name)
    if name ~= GetCurrentResourceName() then return end
    log(("vehicles ready -- runner '%s', cop '%s' (fallback '%s'), offset f%.1f/l%.1f/u%.1f"):format(
        Config.vehicles.runner.record, Config.vehicles.cop.record,
        tostring(Config.vehicles.cop.fallbackRecord),
        Config.vehicles.spawnOffset.forward,
        Config.vehicles.spawnOffset.lateral,
        Config.vehicles.spawnOffset.up))
    log("vehicles NOTE -- the server cannot seat a player; it spawns the car and reminds him")
    assertSpawnGeometry()
    -- A fresh VM cannot own a match, so on start EVERY vehicle the server
    -- attributes to this resource is an orphan of the VM that was replaced.
    -- No grace period is needed or wanted here: waiting one sweep would leave
    -- the wrecks standing for five more seconds and buy nothing.
    log(("vehicles reconciled at start -- %d orphan(s) from a previous VM removed"):format(
        reconcile("start")))
end)

