-- =============================================================================
-- pursuit -- the roster speed cap, client side
-- =============================================================================
--
-- The other half of server/performance.lua. The server owns the NUMBER (it is
-- a Warden tunable, and tunables exist on the server only); this file owns the
-- APPLICATION, because the governor is a client native that scales driver
-- throttle inside the process actually simulating the car.
--
-- -----------------------------------------------------------------------------
-- THIS API DOES NOT EXIST ON EVERY CLIENT, AND THAT MUST NOT BE AN ERROR
-- -----------------------------------------------------------------------------
--
-- `Open77.vehicles.setPerformanceClass` landed after 2.31.0+op77.7, which is
-- the client most people are running right now. On that build the field is
-- simply nil. A bare call would raise, the handler would die, and a HUD feature
-- nobody asked about would take a working chase down with it.
--
-- So every entry into the native goes through `governor()`, which type-checks
-- both functions and answers nil when either is missing, and the miss is
-- reported ONCE as an info line rather than an error. This is the same shape as
-- `callExport` in client/main.lua, which is why a server with no
-- `open77_groundcircle` draws no ring instead of refusing to run: an optional
-- capability is absent, not broken.
--
-- The degraded behaviour is exactly the old behaviour -- every car at its stock
-- top speed, the roster's chassis-class curation doing all the balancing on its
-- own -- so an owner on the old client loses nothing he had.
--
-- -----------------------------------------------------------------------------
-- WHAT THE CAP ACTUALLY TOUCHES
-- -----------------------------------------------------------------------------
--
-- Per TWEAKDB RECORD, so every present and future spawn of a roster car
-- inherits it and there is nothing to re-apply when a match rebuilds its cars.
-- Precedence in the native is instance -> record -> default; this file only
-- ever writes the record tier, so a per-instance profile set by anything else
-- still wins and the global default is never touched. That last part is the
-- reason there is no "cap everything" call here even though one would be
-- shorter: a blanket default would govern city traffic too.
--
-- It is worth being straight about one edge anyway: the police entries ARE
-- records the game's own NCPD traffic uses. Capping `ncpd_villefort_cortes_*`
-- caps an AI patrol car of the same record as well as the cop's. On a dedicated
-- Pursuit server that is a non-issue and arguably correct; it is written down
-- so that nobody re-discovers it as a mystery.
-- =============================================================================

-- The taper the native refuses to go outside, mirrored here so a malformed
-- payload is clamped into a profile the native accepts instead of being
-- rejected wholesale. The bounds are Vehicles.cpp's, not a guess.
local MINIMUM_TAPER_KPH = 3.0
local MAXIMUM_TAPER_KPH = 200.0

-- Last payload received, so a re-apply (world ready, reload) needs no round
-- trip to the server.
local held = nil
-- The "this build has no governor" line is worth saying once and never again.
local absenceNoted = false

local function note(text)
    if Open77 ~= nil and type(Open77.log) == "table" and type(Open77.log.info) == "function" then
        Open77.log.info(text)
    end
end

local function warn(text)
    if Open77 ~= nil and type(Open77.log) == "table" and type(Open77.log.error) == "function" then
        Open77.log.error(text)
    end
end

--- The native, or nil on a client that does not have it.
---
--- Both functions are checked, not just one: a half-present API would leave the
--- "switch the cap off" path unable to undo what the "switch it on" path did.
local function governor()
    local vehicles = Open77 ~= nil and Open77.vehicles or nil
    if type(vehicles) ~= "table" then return nil end
    if type(vehicles.setPerformanceClass) ~= "function" then return nil end
    if type(vehicles.clearPerformanceClass) ~= "function" then return nil end
    return vehicles
end

local function apply(body)
    if type(body) ~= "table" then return end
    held = body

    local vehicles = governor()
    if vehicles == nil then
        if not absenceNoted then
            absenceNoted = true
            note("speed cap not applied: this client build has no " ..
                "Open77.vehicles.setPerformanceClass (it lands after 2.31.0+op77.7). " ..
                "Every car runs at its stock top speed, exactly as before.")
        end
        return
    end

    local records = body.records
    if type(records) ~= "table" or #records == 0 then
        warn("speed cap payload carried no vehicle records; nothing capped")
        return
    end

    local top = tonumber(body.topSpeedKph) or 0.0
    local taper = tonumber(body.taperKph) or 12.0
    local authority = tonumber(body.accelerationScale) or 1.0

    -- Defensive clamps. The tunable bounds already keep an operator inside the
    -- native's own limits; this is here so a payload that arrived some other
    -- way still produces a profile the native accepts rather than an
    -- `invalid_taper` on every single record.
    if top < 0.0 then top = 0.0 end
    if taper < MINIMUM_TAPER_KPH then taper = MINIMUM_TAPER_KPH end
    if taper > MAXIMUM_TAPER_KPH then taper = MAXIMUM_TAPER_KPH end
    if authority <= 0.0 then authority = 0.05 end
    if authority > 1.0 then authority = 1.0 end

    -- A neutral profile is not "set a cap of zero", it is "take the cap off":
    -- the native reads topSpeedKph = 0 as no ceiling, and leaving a neutral
    -- entry in its record table would keep every roster car in the governed set
    -- for no reason.
    local neutral = top <= 0.0 and authority >= 1.0
    local wanted = { topSpeedKph = top, taperKph = taper, accelerationScale = authority }

    local done, failed, firstError = 0, 0, nil
    for _, record in ipairs(records) do
        if type(record) == "string" and record ~= "" then
            local ok, reason
            if neutral then
                ok, reason = vehicles.clearPerformanceClass(record)
            else
                ok, reason = vehicles.setPerformanceClass(record, wanted)
            end
            if ok then
                done = done + 1
            else
                failed = failed + 1
                firstError = firstError or reason
            end
        end
    end

    if failed > 0 then
        -- Not fatal and deliberately not an exception: `native_unavailable`
        -- here means the governor did not attach to this build's drive update,
        -- which is the same "no cap" outcome as the missing export above.
        warn(("speed cap: %d of %d record(s) refused (%s)"):format(
            failed, done + failed, tostring(firstError)))
    end

    if done > 0 then
        note(neutral
            and ("speed cap removed from %d vehicle record(s)"):format(done)
            or ("speed cap %.0f km/h, throttle authority %.2fx, applied to %d vehicle record(s)")
                :format(top, authority, done))
    end
end

local function requestSync()
    local sent, reason = TriggerServerEvent("pursuit:performance:sync")
    if not sent then
        warn("speed cap sync not requested: " .. tostring(reason))
    end
end

RegisterNetEvent("pursuit:performance", function(body)
    apply(body)
end)

-- Two entry points, for the two ways this VM comes up.
--
-- `onClientResourceStart` covers a HOT RELOAD, where the world has been live
-- for ages and `open77:worldReady` will never fire again -- the same trap
-- client/main.lua documents at its own reload handler.
--
-- `open77:worldReady` covers a fresh session, and re-applies what we already
-- hold as well as asking again: the record table lives in the plugin rather
-- than in this VM, so re-applying it is cheap insurance against anything else
-- having called `clearAllPerformance`.
AddEventHandler("onClientResourceStart", function(name)
    if name ~= GetCurrentResourceName() then return end
    requestSync()
end)

AddEventHandler("open77:worldReady", function()
    if held ~= nil then apply(held) end
    requestSync()
end)
