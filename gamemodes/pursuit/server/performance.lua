-- =============================================================================
-- pursuit -- the roster speed cap, server side
-- =============================================================================
--
-- WHAT THIS FILE IS FOR. Pursuit is decided by two cars, and until now which
-- car you were handed was part of the result: the measured pair rate 115 km/h
-- (`v_standard2_archer_hella_player`, the runner's) against 140 km/h
-- (`ncpd_villefort_cortes_heat_1`, the cop's). `shared/roster.lua` answers that
-- by CURATION -- one chassis class, no mixing -- and its section 1 explains at
-- length that a technical cap does not exist. THAT WAS TRUE WHEN IT WAS
-- WRITTEN. It is not any more: a native throttle governor now sits behind
-- `Open77.vehicles.setPerformanceClass`, and this file and its client half are
-- the wiring that points it at the roster.
--
-- Roster.lua has deliberately NOT been re-argued here. It is a byte-identical
-- copy of `resources/system/open77_vehiclepicker/shared/roster.lua` and must stay one;
-- the correction belongs upstream, in the picker, not in a fork of it.
--
-- -----------------------------------------------------------------------------
-- WHY THE WORK IS SPLIT ACROSS TWO VMs
-- -----------------------------------------------------------------------------
--
-- The governor is a CLIENT native. It scales driver throttle on the wheeled
-- drive update, in the process that is actually simulating the car, and there
-- is no server-side equivalent -- `Open77.vehicles` on this side is create,
-- remove, update and read, and none of its eleven writable fields is a
-- performance field. So the cap can only be applied where the driving happens.
--
-- But the NUMBER is a tunable, and tunables exist on the server only
-- (`Open77.tunables` is nil in a client VM; see the header of
-- shared/config.lua). Hence: this file owns the value and pushes it, and
-- client/performance.lua owns the application.
--
-- The payload carries the record list rather than letting the client read
-- `Open77VehicleRoster` itself. Both sides do have the roster -- it is a
-- shared_script -- but sending it means the SERVER's roster is the one that
-- decides, which is the rule the rest of this gamemode plays by.
--
-- -----------------------------------------------------------------------------
-- APPLY TIMING, AND WHY THIS FILE NEVER CALLS promote()
-- -----------------------------------------------------------------------------
--
-- `topSpeedKph` and `throttleAuthority` are declared `next_match`. That means
-- `Open77.tunables.get` keeps answering the OLD number until something calls
-- `Open77.tunables.promote()`, and the only thing that does is
-- `server/match.lua`, at match creation. So this file simply re-reads the
-- effective value on the events that follow a match being created and pushes
-- it when it has moved. It never promotes anything itself: a second promoter
-- would land a new ceiling in the middle of somebody's chase, which is the
-- exact failure `next_match` exists to prevent.
--
-- The visible consequence, stated so nobody files it as a bug: ON A SERVER
-- WHERE NO MATCH IS EVER CREATED, A CHANGE NEVER LANDS. Warden says so -- it
-- shows the key as pending -- and that is the honest reading of "next match".
--
-- ONE HONEST LIMITATION, since the rest of this mode does better. Every other
-- rule is CAPTURED per match (`match.tune`), so two matches in two routing
-- buckets can legitimately play by different numbers. The cap cannot: it is a
-- per-record policy inside each client's plugin, and a record is global to that
-- client. So with two matches in flight the promotion that serves the newer one
-- moves the ceiling for both. It is bounded -- it can only happen at a match
-- creation, never mid-round for the mode that is alone on the server -- and
-- closing it properly would mean capping per INSTANCE, per spawned car, which
-- the native supports and this wiring deliberately does not use yet.
-- =============================================================================

local function log(text)
    print("[pursuit] " .. text)
end

-- The record list is static for the life of the VM: it comes from the roster
-- and from Config, neither of which changes without a reload. Built on first
-- use rather than at file scope, so load order cannot leave it empty forever.
local recordCache = nil

local function records()
    if recordCache ~= nil then return recordCache end

    local out, seen = {}, {}
    local function add(record)
        if type(record) ~= "string" or record == "" then return end
        if seen[record] then return end
        seen[record] = true
        out[#out + 1] = record
    end

    -- The roster the picker offers, BOTH lists, and each entry's `fallback` as
    -- well as its `record`. The fallback matters: an unverified NCPD record
    -- that refuses to create is retried as the `*_player` car
    -- (server/vehicles.lua), and a fallback that outran the cap would undo the
    -- point of the cap at exactly the moment the mode was already degrading.
    local roster = Open77VehicleRoster
    if type(roster) == "table" and type(roster.lists) == "table" then
        for _, list in pairs(roster.lists) do
            for _, entry in ipairs(list.entries or {}) do
                add(entry.record)
                add(entry.fallback)
            end
        end
    end

    -- The default pair from Config, which is what a match spawns when nobody
    -- opened the picker. Both are already in the roster today; adding them
    -- costs nothing and stops the cap silently missing the default match if
    -- the two lists ever drift apart.
    local vehicles = type(Config) == "table" and Config.vehicles or nil
    if type(vehicles) == "table" then
        local runner = vehicles.runner
        local cop = vehicles.cop
        if type(runner) == "table" then add(runner.record) end
        if type(cop) == "table" then
            add(cop.record)
            add(cop.fallbackRecord)
        end
    end

    recordCache = out
    return out
end

-- Declared defaults, read out of the tunable declaration itself so this file
-- carries no second copy of a number that lives in shared/config.lua. Reached
-- only when a tunable read fails outright, which means the declaration did not
-- land -- at which point a sane number beats a nil.
local function declaredDefault(key, fallback)
    local tunables = type(Config) == "table" and Config.tunables or nil
    local entry = type(tunables) == "table" and tunables[key] or nil
    local value = type(entry) == "table" and tonumber(entry.value) or nil
    return value or fallback
end

local function taperKph()
    local vehicles = type(Config) == "table" and Config.vehicles or nil
    local performance = type(vehicles) == "table" and vehicles.performance or nil
    local value = type(performance) == "table" and tonumber(performance.taperKph) or nil
    return value or 12.0
end

-- The EFFECTIVE profile: what a match created right now would play by. Read at
-- the point of use, never cached in a file-scope local -- that is the one rule
-- for tunable authors (docs/writing-a-gamemode.md 8.2), and caching here would
-- make the panel report a number nothing obeys.
local function profile()
    local top = Open77.tunables.get("topSpeedKph")
    local authority = Open77.tunables.get("throttleAuthority")
    return {
        topSpeedKph = tonumber(top) or declaredDefault("topSpeedKph", 0.0),
        taperKph = taperKph(),
        accelerationScale = tonumber(authority) or declaredDefault("throttleAuthority", 1.0),
    }
end

-- Last profile actually broadcast, so the handlers below can fire as often as
-- they like and cost one comparison of three numbers when nothing moved.
local broadcast = nil

local function same(a, b)
    return a ~= nil and b ~= nil
        and a.topSpeedKph == b.topSpeedKph
        and a.taperKph == b.taperKph
        and a.accelerationScale == b.accelerationScale
end

local function describe(current)
    local ceiling = current.topSpeedKph > 0
        and ("%.0f km/h"):format(current.topSpeedKph)
        or "off (stock top speed)"
    return ("%s, throttle authority %.2fx, taper %.0f km/h, %d record(s)"):format(
        ceiling, current.accelerationScale, current.taperKph, #records())
end

local function payload(current)
    return {
        topSpeedKph = current.topSpeedKph,
        taperKph = current.taperKph,
        accelerationScale = current.accelerationScale,
        records = records(),
    }
end

--- Send the current profile to ONE player. This answers a client that has just
--- started or reloaded, and it is the only reliable moment to catch one: there
--- is no player enumeration on this host, so a broadcast at resource start
--- cannot reach a client whose VM is not up yet.
local function sendTo(playerId)
    -- `tonumber` rather than a type test: player ids reach a gamemode as numbers
    -- through `source` but as STRINGS through `onPlayerConnected`
    -- (docs/writing-a-gamemode.md 2.3), and this refusing to answer a client
    -- because of that would be a silent no-cap.
    local id = tonumber(playerId)
    if id == nil or id <= 0 then return end
    local current = profile()
    local ok, reason = TriggerClientEvent("pursuit:performance", id, payload(current))
    if not ok then
        log(("speed cap not sent to player %d: %s"):format(id, tostring(reason)))
    end
end

--- Broadcast, but only when the effective numbers actually moved.
local function pushIfChanged(why)
    local current = profile()
    if same(broadcast, current) then return false end
    broadcast = current
    local ok, reason = TriggerClientEvent("pursuit:performance", -1, payload(current))
    if not ok then
        -- Forget what we thought we had sent, so the next event retries rather
        -- than concluding the clients are already up to date.
        broadcast = nil
        log(("speed cap broadcast failed (%s): %s"):format(tostring(why), tostring(reason)))
        return false
    end
    log(("speed cap now %s -- %s"):format(describe(current), tostring(why)))
    return true
end

-- A client that has just come up asks for the current figures. Belt and braces
-- with the broadcasts below: whichever of the two VMs was ready first, the
-- client ends up holding the same numbers.
RegisterNetEvent("pursuit:performance:sync", function()
    sendTo(source)
end)

-- The two events that follow a match being created, and therefore follow
-- `server/match.lua` calling promote(). Either would do on its own; both are
-- registered because `stateChanged` fires as players are moved into the
-- countdown -- so the cars are capped before anyone can drive them -- while
-- `matchStarted` is the one that still fires if a future path reaches the
-- active state by another route. Both are no-ops when nothing moved.
AddEventHandler("pursuit:stateChanged", function()
    pushIfChanged("promoted at match creation")
end)

AddEventHandler("pursuit:matchStarted", function()
    pushIfChanged("promoted at match creation")
end)

-- Operator feedback, and the `live` path if these keys are ever redeclared as
-- live. A `next_match` write arrives here with pending = true and deliberately
-- changes nothing yet; saying so in the log is what stops "I moved it and
-- nothing happened" becoming a bug report.
AddEventHandler("onTunableChanged", function(key, value, pending)
    if key ~= "topSpeedKph" and key ~= "throttleAuthority" then return end
    if pending then
        log(("%s set to %s -- held until the next match is created (apply = next_match)"):format(
            tostring(key), tostring(value)))
        return
    end
    pushIfChanged(("%s changed"):format(tostring(key)))
end)

AddEventHandler("onResourceStart", function(name)
    if name ~= GetCurrentResourceName() then return end
    local current = profile()
    broadcast = current
    local ok, reason = TriggerClientEvent("pursuit:performance", -1, payload(current))
    if not ok then
        broadcast = nil
        log(("speed cap not broadcast at start: %s"):format(tostring(reason)))
    end
    log(("speed cap %s"):format(describe(current)))

    -- server/match.lua runs a start-up check that every declared tunable is
    -- read somewhere, and it knows only the keys IT reads. It will therefore
    -- have printed a TUNING WARNING naming these two as "read nowhere" a few
    -- lines above this one. They are read here. Correcting it immediately
    -- afterwards is the least bad answer available to this file: the warning
    -- lands in a production log, and a stale warning is worse than no warning.
    -- The real fix is one entry in that check's `wired` list, in a file this
    -- change does not own.
    log("note: `topSpeedKph` and `throttleAuthority` are read by this file " ..
        "(server/performance.lua) -- any TUNING WARNING above that names them " ..
        "is match.lua's wired-key list not having heard of them yet")
end)
