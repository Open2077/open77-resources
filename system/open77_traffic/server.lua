-- The generator settings are declared in shared/config.lua and owned by the
-- host (`Open77.tunables`): the panel, the Warden form and the console all
-- write the same validated, persisted values, and the host enforces the
-- declared bounds on every one of them. They are captured ONCE into CONFIG and
-- kept in step by the onTunableChanged handler below, because the admission
-- tests in the spawn scan -- the fleet separation walk in particular -- run
-- thousands of times per selection pass, and a host getter in that
-- inner loop would be a cross-VM call per comparison.
assert(type(TrafficSettings) == "table", "shared/config.lua was not loaded before server.lua")
-- Generation is opt-in per server profile: a `"*"` load list picks this resource
-- up, so it declares `enabled = false` unless the profile's convars set
-- `open77_traffic_enabled`. This only chooses the default; a value the operator
-- persisted (panel, Warden, `tunable.set`) still wins.
TrafficSettings.enabled.value = GetConvarBool("open77_traffic_enabled", false)
Open77.tunables.declare(TrafficSettings)

-- key -> value, read as a bare field at every use site below.
local CONFIG = Open77.tunables.capture()

local function finite(value)
    return type(value) == "number" and value == value
        and value ~= math.huge and value ~= -math.huge
end

-- Re-checked once at load. The declaration is what bounds a write, so a value
-- outside its own bounds would mean the host applied something this resource
-- never declared -- and a scan running on a value like that is the one outcome
-- the declared bounds exist to prevent.
for key, spec in pairs(TrafficSettings) do
    local value = CONFIG[key]
    assert(value ~= nil, ("tunable '%s' was not declared by the host"):format(key))
    if spec.type == "boolean" then
        assert(type(value) == "boolean", ("tunable '%s' is not a boolean"):format(key))
    elseif spec.type == "text" then
        assert(type(value) == "string", ("tunable '%s' is not text"):format(key))
    else
        assert(finite(value), ("tunable '%s' is not a finite number"):format(key))
        if spec.type == "integer" then
            assert(value % 1 == 0, ("tunable '%s' is not a whole number"):format(key))
        end
        if spec.min then
            assert(value >= spec.min, ("tunable '%s' is below its declared minimum"):format(key))
        end
        if spec.max then
            assert(value <= spec.max, ("tunable '%s' is above its declared maximum"):format(key))
        end
    end
end

-- The derived numbers the scan reads instead of the host:
--
--   * The fleet gate compares SQUARED centre-to-centre distances. It only
--     ever asks "closer than", and both operands are non-negative, so the
--     square answers exactly what the square root answered -- without a
--     math.sqrt per (candidate, own car) pair, which is the inner loop the
--     selection pass spends its budget in.
--     The final clearance guard still asks the canonical registry for real
--     distances at the exact create point.
--   * The clearance radius is the centre-to-centre exclusion that guard claims
--     for a new spawn: at least 20 m, or a larger configured
--     `minimumSpawnSeparation`. It is a conservative point-to-point number, NOT
--     a body-shape test -- the canonical registry carries no vehicle bounds, so
--     no per-record footprint is guessed.
--   * The scan separation is that same clearance radius, not the raw setting:
--     a candidate closer to an own car than the create guard allows would be
--     refused at create time every time, after a client ground probe was
--     already paid for it.
--   * The player exclusion is `minimumPlayerSpawnDistance`, squared and
--     measured in the horizontal plane (see `playerExclusionState`).
local SPAWN_CLEARANCE_RADIUS, MINIMUM_SEPARATION_SQUARED, PLAYER_EXCLUSION_SQUARED

local function recomputeDerived()
    SPAWN_CLEARANCE_RADIUS = math.max(20, CONFIG.minimumSpawnSeparation)
    MINIMUM_SEPARATION_SQUARED = SPAWN_CLEARANCE_RADIUS * SPAWN_CLEARANCE_RADIUS
    PLAYER_EXCLUSION_SQUARED = CONFIG.minimumPlayerSpawnDistance * CONFIG.minimumPlayerSpawnDistance
end

-- The relations between keys that no single key's bounds can express (see
-- shared/config.lua): a candidate has to be inside the spawn band around its
-- player, so a minimum player distance above the probe radius admits nothing at
-- all; and it also has to be inside the player's area, so an area radius at
-- or below that distance leaves a standing player no spawn. The panel refuses
-- such a write and names the pair; an external write cannot be refused after
-- the fact, so it is applied, logged, and every gate stays conservative on its
-- own numbers.
--
-- There is deliberately no relation between `minimumSpawnSeparation` and
-- `groundProbeRadius`: the separation is between two cars and the probe radius
-- is from a player, so a separation wider than the band is a legitimate way to
-- admit fewer cars -- and with an empty fleet it admits them normally.
local function relationMessage(values)
    if values.minimumPlayerSpawnDistance > values.groundProbeRadius then
        return ("%s (%s m) is above %s (%s m), so no car could spawn")
            :format(TrafficSettings.minimumPlayerSpawnDistance.label, tostring(values.minimumPlayerSpawnDistance),
                TrafficSettings.groundProbeRadius.label:lower(), tostring(values.groundProbeRadius))
    end
    if values.playerAreaRadius <= values.minimumPlayerSpawnDistance then
        return ("%s (%s m) is not above %s (%s m), so a standing player gets no car")
            :format(TrafficSettings.playerAreaRadius.label, tostring(values.playerAreaRadius),
                TrafficSettings.minimumPlayerSpawnDistance.label:lower(), tostring(values.minimumPlayerSpawnDistance))
    end
    return nil
end

-- One line naming every effective value, so an operator can see that a saved
-- override survived a restart instead of inferring it from the panel.
local function settingsSummary()
    local parts = {}
    for key in pairs(TrafficSettings) do
        parts[#parts + 1] = ("%s=%s"):format(key, tostring(CONFIG[key]))
    end
    table.sort(parts)
    return table.concat(parts, " ")
end

recomputeDerived()

-- An appearance is an engine lookup, not free text: an empty name or the
-- engine's "random" sentinel hands the look back to each client's own engine
-- draw, which is the per-client divergence these pools remove. 128 bytes is
-- the replicated appearance bound for both entity types.
local function validateAppearancePool(pool, label)
    assert(type(pool) == "table" and #pool > 0, label .. " has no pool")
    for index, name in ipairs(pool) do
        assert(type(name) == "string" and name ~= "",
            ("%s[%d] is not a name"):format(label, index))
        assert(name ~= "random",
            ("%s[%d] delegates to the engine random draw"):format(label, index))
        assert(#name <= 128,
            ("%s[%d] exceeds the replicated appearance bound"):format(label, index))
    end
end

local function loadValidatedPopulation()
    local catalog = Open77TrafficPopulationCatalog
    Open77TrafficPopulationCatalog = nil
    assert(type(catalog) == "table", "validated population catalog was not loaded")
    assert(catalog.schema == 1, "unsupported population catalog schema")
    assert(catalog.runtimeValidated == true, "population catalog is not runtime validated")
    assert(type(catalog.profiles) == "table" and #catalog.profiles > 0, "population catalog is empty")

    local names = {}
    local totalWeight = 0
    for index, profile in ipairs(catalog.profiles) do
        local label = ("profile[%d]"):format(index)
        assert(type(profile.name) == "string" and profile.name ~= "", label .. " has no name")
        assert(not names[profile.name], label .. " duplicates " .. profile.name)
        names[profile.name] = true
        assert(profile.runtimeValidated == true, label .. " is not runtime validated")
        assert(type(profile.vehicleRecord) == "string"
            and profile.vehicleRecord:match("^Vehicle%."), label .. " has an invalid vehicle record")
        assert(type(profile.driverRecord) == "string"
            and profile.driverRecord:match("^Character%."), label .. " has an invalid driver record")
        assert(finite(profile.weight) and profile.weight >= 1 and profile.weight % 1 == 0,
            label .. " has an invalid weight")
        validateAppearancePool(profile.vehicleAppearances, label .. " vehicle appearance")
        validateAppearancePool(profile.driverAppearances, label .. " driver appearance")
        totalWeight = totalWeight + profile.weight
        assert(totalWeight <= 1024, "population catalog has excessive total weight")
    end
    return catalog.profiles, totalWeight
end

local POPULATION, POPULATION_WEIGHT = loadValidatedPopulation()

-- The spawn catalogue (scripts/build-traffic-spans.py): one span per authored
-- crowd fragment on a drivable road lane, and spawn samples along it, keyed
-- `-sampleId`. The manifest loads it before this script, so it is always
-- present.
local function loadSpans()
    local catalog = Open77TrafficSpanCatalog
    Open77TrafficSpanCatalog = nil
    assert(type(catalog) == "table" and catalog.schema == 1, "unsupported span catalog schema")
    assert(finite(catalog.gridSizeM) and catalog.gridSizeM > 0, "span catalog has invalid grid size")
    assert(finite(catalog.sampleIdBase) and catalog.sampleIdBase > 0, "span catalog has invalid sample ids")
    assert(type(catalog.spans) == "table" and type(catalog.cells) == "table", "span catalog is empty")
    local spans = {}
    for index, row in ipairs(catalog.spans) do
        -- Not assert(cond, msg:format()): that formats the message on every
        -- row, and this loop runs inside the 1,000,000-instruction load quota.
        if not (row[1] == index and #row == 16 and row[4] > row[3]) then
            error(("span[%d] is invalid"):format(index), 0)
        end
        spans[index] = { length = (row[4] - row[3]) / 1000, periods = row, samples = 0 }
    end
    local sampleCount = 0
    for key, cell in pairs(catalog.cells) do
        for _, sample in ipairs(cell) do
            local span = spans[sample[8]]
            if not (span and sample[1] > catalog.sampleIdBase) then
                error(("span cell %s has an invalid sample"):format(key), 0)
            end
            span.samples = span.samples + 1
            sampleCount = sampleCount + 1
        end
    end
    return { spans = spans, spanCount = #spans, sampleCount = sampleCount, cells = catalog.cells,
        gridSize = catalog.gridSizeM, sampleIdBase = catalog.sampleIdBase }
end
local SPANS = loadSpans()

local cars = {}
-- driver NPC id -> the tracked car it drives: the one index a player's hit
-- report or a death announcement is resolved through, so neither walks the
-- fleet. It holds exactly the drivers of the cars in `cars`.
local driverCars = {}
-- Killed drivers whose bodies are still in the world, by NPC id. Their cars
-- have already left `cars`; see `keepCorpse` and `sweepCorpses`.
local corpses = {}
local corridorRuntimeByBucket = {}
local rejectedCorridors = {}
local stopping = false
-- Spawn work is fenced by generation, not by cancellation: every suspension
-- point in a spawn pass (the scan's Wait(0), the client ground probe, a
-- saturated Wait) can leave a selection that was made with settings, a fleet
-- and a corridor reservation the current run no longer has. A pass captures
-- this counter when it starts and refuses to create once it has moved -- which
-- is what makes a settings change and a fleet reset take effect at once
-- instead of one stale candidate later.
local generation = 0
-- True only for the duration of a reset. Creation is blocked while it holds, so
-- the gap the deletion yields in cannot be filled with a car the reset has
-- already walked past.
local resetting = false
local rejectedProfiles = {}
-- A corridor whose client ground probe kept failing is benched for a while,
-- not for the run: the probing client may simply still have been streaming
-- the area in. So is one whose cars keep failing to join traffic right after
-- spawning (see `noteJoinOutcome`), and a whole source lane whose cars keep
-- crashing out of traffic right after spawning (see `noteImpactFailure`).
-- Each bucket owns its reservations and its ground-query, join and impact
-- history.
local CORRIDOR_QUARANTINE_SECONDS = 300
local JOIN_FAILURE_SECONDS = 10
local JOIN_FAILURE_LIMIT = 2
local IMPACT_FAILURE_SECONDS = 120
local IMPACT_FAILURE_WINDOW_SECONDS = 180
local IMPACT_FAILURE_LIMIT = 2
-- Per-attempt refusals happen many times a second; they are counted here and
-- summarised by the monitor thread instead of logged one line each, because
-- the log is written synchronously on the server tick thread. Fence refusals
-- (a pass outliving a reset, a settings change or its player) are rare and
-- name their cause, so they keep their own line.
local DEFERRAL_REPORT_SECONDS = 10
local deferrals = { precheck = 0, clearance = 0, fleetMoved = 0, groundMiss = 0 }
local deferralsReportedAt = Open77.time.monotonic()
-- Observation is deliberately separate from authority eligibility. A connected
-- player whose last pose is old can still see the street (death, a stalled
-- upload). The dated read keeps that exclusion until departure/bucket change;
-- only the fresh roster below may select a simulator.
local UNOBSERVED_GRACE_SECONDS = 10

local function observationPositions()
    local roster = Open77.players.all()
    if type(roster) ~= "table" then return nil end
    local positions = {}
    for _, id in pairs(roster) do
        local read = Open77.players.get(id)
        local position = type(read) == "table" and read.position
        -- An active player loading or changing buckets has no located body
        -- yet. Unknown is not an empty street; defer placement/retirement.
        if type(position) ~= "table" or not finite(position.x)
            or not finite(position.y) or not finite(position.z) then return nil end
        positions[tonumber(id) or id] = { x = position.x, y = position.y, z = position.z,
            bucket = read.bucket or 0, velocity = read.velocity, ageMs = read.ageMs }
    end
    return positions
end

local function resetDeferrals()
    for key in pairs(deferrals) do deferrals[key] = 0 end
end

local function corridorRuntime(bucket)
    local runtime = corridorRuntimeByBucket[bucket]
    if not runtime then
        runtime = { use = {}, groundFailures = {}, joinFailures = {}, quarantineUntil = {},
            impactFailures = {}, laneQuarantineUntil = {}, spanCooldownUntil = {} }
        corridorRuntimeByBucket[bucket] = runtime
    end
    runtime.lastUsedAt = Open77.time.monotonic()
    return runtime
end

local function corridorQuarantined(runtime, corridorIndex)
    local untilSeconds = runtime.quarantineUntil[corridorIndex]
    if not untilSeconds then return false end
    if Open77.time.monotonic() < untilSeconds then return true end
    runtime.quarantineUntil[corridorIndex] = nil
    return false
end

-- A span sample's lane quarantine key is its lane id in the span catalogue.
local function laneKey(corridor)
    return corridor[2]
end

local function laneQuarantined(runtime, lane)
    local untilSeconds = runtime.laneQuarantineUntil[lane]
    if not untilSeconds then return false end
    if Open77.time.monotonic() < untilSeconds then return true end
    runtime.laneQuarantineUntil[lane] = nil
    return false
end
local rngState = (math.floor(Open77.time.unix()) + math.floor(Open77.time.monotonic() * 1000000)) % 2147483647
if rngState <= 0 then rngState = 1 end
local populationBag = {}
local populationCursor = 1

local function nextRandom(limit)
    rngState = (rngState * 48271) % 2147483647
    return (rngState % limit) + 1
end

local function refillPopulationBag()
    populationBag = {}
    for profileIndex, profile in ipairs(POPULATION) do
        for _ = 1, profile.weight do populationBag[#populationBag + 1] = profileIndex end
    end
    for index = #populationBag, 2, -1 do
        local other = nextRandom(index)
        populationBag[index], populationBag[other] = populationBag[other], populationBag[index]
    end
    populationCursor = 1
end

local function selectPopulation()
    for _ = 1, POPULATION_WEIGHT do
        if populationCursor > #populationBag then refillPopulationBag() end
        local profileIndex = populationBag[populationCursor]
        populationCursor = populationCursor + 1
        if not rejectedProfiles[profileIndex] then
            return profileIndex, POPULATION[profileIndex]
        end
    end
    return nil
end

local function log(format, ...)
    print(("[open77_traffic] " .. format):format(...))
end

log("population seed=%d with %d qualified profile(s), total weight %d",
    rngState, #POPULATION, POPULATION_WEIGHT)
log("loaded %d span(s) with %d spawn sample(s)", SPANS.spanCount, SPANS.sampleCount)
log("settings: %s", settingsSummary())
local startupProblem = relationMessage(CONFIG)
if startupProblem then
    log("warning: %s, until the pair is consistent", startupProblem)
end

-- How many cars one command or setting sweep walks before yielding to the
-- scheduler. These run under the same instruction quota as a spawn pass and
-- walk the whole tracked fleet or registry, so a fleet big enough to matter must
-- be able to span ticks instead of exhausting the quota: a reset holds creation
-- blocked for its whole duration, and a snapshot merely reads across ticks.
local COMMAND_WORK_PER_RESUME = 64

-- The damage policy a driver is created with and switched to. `immortal`
-- while drivers may not be killed: `create`'s own default and what traffic
-- drivers had before they became killable. The server floors its health at 1,
-- every client shields the projected body from death (the keyed barrier any
-- non-mortal NPC gets), and no client claims or reports a priced hit on it,
-- because only a mortal driver's damage is claimed.
local function driverDamagePolicy()
    return CONFIG.driversKillable and Open77.npcs.damage.mortal or Open77.npcs.damage.immortal
end

-- `driversKillable` reaches the living drivers of the tracked fleet at once.
-- A killed driver is left as it is: its death is final and its body is the
-- corpse sweep's. The ids are collected first because the walk yields while
-- the monitor keeps retiring cars, and each driver reads the value in force
-- when it is reached, so a second toggle during the walk never loses to it.
local function applyDriverPolicy()
    local ids = {}
    for driverId in pairs(driverCars) do ids[#ids + 1] = driverId end
    local changed, failed = 0, 0
    for index = 1, #ids do
        local driverId = ids[index]
        local npc = Open77.npcs.get(driverId)
        local policy = driverDamagePolicy()
        if type(npc) == "table" and finite(npc.health) and npc.health > 0 and npc.damagePolicy ~= policy then
            if Open77.npcs.setDamagePolicy(driverId, policy) == true then
                changed = changed + 1
            else
                failed = failed + 1
            end
        end
        if index % COMMAND_WORK_PER_RESUME == 0 and index < #ids then Wait(0) end
    end
    log("driversKillable=%s: %d living driver(s) switched, %d refused",
        tostring(CONFIG.driversKillable), changed, failed)
end

-- `carsStealable` reaches every car this resource created, not only the
-- tracked fleet: a wreck, a handed-over or stolen car and a killed driver's car
-- have all left `cars`, and the canonical registry filtered on the creating
-- resource is the only list of them (see `resetFleet`). The lock is the
-- registry's own server-only bit, set for everyone with every per-player
-- exception revoked: the server refuses every seat request on a locked car --
-- so a killed driver's body is never stolen and stays seated -- and every
-- client shows vanilla's locked door and offers no way in. Ownership and the
-- value in force are read again per car, because the walk yields.
local function applyCarLocks()
    local ids = {}
    local name = GetCurrentResourceName()
    local registry = Open77.vehicles.all()
    for index = 1, #registry do
        local vehicle = registry[index]
        local id = type(vehicle) == "table" and vehicle.resource == name and tonumber(vehicle.id) or nil
        if id then ids[#ids + 1] = id end
        if index % COMMAND_WORK_PER_RESUME == 0 and index < #registry then Wait(0) end
    end
    local applied, failed = 0, 0
    for index = 1, #ids do
        local vehicle = Open77.vehicles.get(ids[index])
        if vehicle and (type(vehicle.resource) ~= "string" or vehicle.resource == name) then
            if Open77.vehicles.setLockedForAll(ids[index], not CONFIG.carsStealable) == true then
                applied = applied + 1
            else
                failed = failed + 1
            end
        end
        if index % COMMAND_WORK_PER_RESUME == 0 and index < #ids then Wait(0) end
    end
    log("carsStealable=%s: %d car(s) %s, %d refused", tostring(CONFIG.carsStealable),
        applied, CONFIG.carsStealable and "unlocked" or "locked", failed)
end

-- Adopt one accepted value: the host has already validated it against the
-- declaration, stored it and persisted it. The derived radii are re-computed
-- here so the next comparison uses the new numbers, and the generation moves so
-- a pass that selected under the old ones cannot create under the new ones. The
-- two player settings also reach the drivers and cars already in the world.
local function applySetting(key, value)
    if TrafficSettings[key] == nil then return false end
    CONFIG[key] = value
    recomputeDerived()
    generation = generation + 1
    local problem = relationMessage(CONFIG)
    if problem then
        log("warning: %s, until the pair is consistent", problem)
    end
    log("setting %s=%s applied at generation %d", key, tostring(value), generation)
    if key == "driversKillable" then
        applyDriverPolicy()
    elseif key == "carsStealable" then
        applyCarLocks()
    end
    return true
end

-- The host owns the values and is the only writer, so this handler adopts
-- rather than re-checks. Nothing in this declaration defers its apply, so
-- `pending` is always false here; a value waiting on a boundary would be a
-- declaration mistake, and adopting it early would be the bug it exists to
-- prevent, so it is logged instead of applied.
AddEventHandler("onTunableChanged", function(key, value, pending)
    if TrafficSettings[key] == nil then return end
    if pending then
        log("setting %s waited on a boundary this resource never declares", key)
        return
    end
    value = Open77.tunables.get(key)
    if CONFIG[key] == value then return end
    applySetting(key, value)
end)

local function populationCounts()
    local total = 0
    for _ in pairs(cars) do total = total + 1 end
    return total, total
end

-- Roster collection, post-yield validation and the create-point player
-- exclusion all require a ready, living player.
local function playerLive(playerId)
    local ready = playerId ~= nil and type(Open77.ready) == "table"
        and type(Open77.ready.isReady) == "function"
        and Open77.ready.isReady(playerId) == true
    local life = playerId ~= nil and type(Open77.players.getLifeState) == "function"
        and Open77.players.getLifeState(playerId) or nil
    return ready and type(life) == "table" and life.phase == "alive"
end

-- The spawn scan reads the player's velocity to lean the spawn band ahead (see
-- `candidatePlacement`).
local function playerVelocity(playerId)
    local read = Open77.players.get(playerId)
    local velocity = type(read) == "table" and read.velocity
    if type(velocity) == "table" and finite(velocity.x) and finite(velocity.y) then return velocity end
    return nil
end

local function playerAnchor(playerId, position)
    if playerLive(playerId) and position and position.x and position.y and position.z then
        return {
            id = playerId,
            position = position,
            bucket = position.bucket or 0,
            velocity = playerVelocity(playerId),
        }
    end
    return nil
end

local function activePlayers()
    observationPositions()
    local rows = {}
    for playerId, position in pairs(Open77.players.positions() or {}) do
        local row = playerAnchor(tonumber(playerId), position)
        if row then rows[#rows + 1] = row end
    end
    return rows
end

-- A selection or ground probe may span ticks; never trust its old player row.
local function currentPlayerAnchor(playerId)
    local positions = Open77.players.positions()
    if type(positions) ~= "table" then return nil end
    return playerAnchor(playerId, positions[playerId])
end

-- Refresh the participating players before each fallback attempt.
local function refreshAnchors(anchors)
    local positions = Open77.players.positions()
    if type(positions) ~= "table" then return {} end
    local rows = {}
    for index = 1, #anchors do
        local row = playerAnchor(anchors[index].id, positions[anchors[index].id])
        if row then rows[#rows + 1] = row end
    end
    return rows
end

local function admissionAvailable(playerId, capacity)
    capacity = capacity or Open77.vehicles.ai.capacity()
    return (capacity.owners[tostring(playerId)] or 0) < capacity.perSimulatorLimit
end

local function remainingNpcCapacity()
    local capacity = Open77.npcs.capacity()
    return math.max(0, math.min(capacity.resourceLimit - capacity.resourceUsed,
        capacity.globalLimit - capacity.globalUsed))
end

local function currentBudget(players, capacity)
    capacity = capacity or Open77.vehicles.ai.capacity()
    local available = 0
    for _, player in ipairs(players) do
        available = available + math.max(0,
            capacity.perSimulatorLimit - (capacity.owners[tostring(player.id)] or 0))
    end
    return math.min(CONFIG.carsGlobal, populationCounts() + math.min(available, remainingNpcCapacity()))
end

local function corridorName(corridor)
    return ("span-%d-%d"):format(corridor[8], corridor[3])
end

local function corridorAnchor(corridor)
    return { x = corridor[4], y = corridor[5], z = corridor[6], yaw = corridor[7] }
end

-- Wait(0) resumes on the next host tick. The quota is shared with the retirement
-- monitor, so leave headroom for it and for the yield-free create path. These
-- weights bound work, not exact VM instructions: native reads cost more than
-- snapshot comparisons. Both outer candidates and inner fleet walks spend here.
local SCAN_WORK_PER_RESUME = 4096
local SCAN_WORK_COMPARISON = 2
local SCAN_WORK_CANDIDATE = 4
local SCAN_WORK_FLEET_READ = 12
local scanWork = 0

local function scanSpend(units)
    scanWork = scanWork + units
    if scanWork >= SCAN_WORK_PER_RESUME then
        scanWork = 0
        Wait(0)
    end
end

local function corridorPoint(corridor)
    return corridor[4], corridor[5], corridor[6]
end

-- Share the spawn band between selection and post-yield validation. The outer
-- edge is the 3D reach of the ground probe; the inner edge is the same
-- horizontal player exclusion the create point is guarded with, so the scan
-- never offers its selecting player a candidate that guard would refuse.
--
-- A fast player gets no candidate in the half-plane behind them: such a car is
-- out of their area within seconds, and each attempt costs one serial client
-- ground probe that a point ahead could have used (merge7, 160 km/h: up to 12
-- of ~25 spawns per 10 s behind).
local NATIVE_FORWARD_ONLY_SPEED = 10
local function behindFastPlayer(player, dx, dy)
    local velocity = player.velocity
    if not velocity then return false end
    local speed = math.sqrt(velocity.x * velocity.x + velocity.y * velocity.y)
    return speed >= NATIVE_FORWARD_ONLY_SPEED and dx * velocity.x + dy * velocity.y < 0
end

local function candidatePlacement(corridor, player)
    local position = player.position
    local x, y, z = corridorPoint(corridor)
    local dx, dy, dz = x - position.x, y - position.y, z - position.z
    local planar = dx * dx + dy * dy
    if planar < PLAYER_EXCLUSION_SQUARED then return nil end
    local distance = math.sqrt(planar + dz * dz)
    if distance > CONFIG.groundProbeRadius then return nil end
    if behindFastPlayer(player, dx, dy) then return nil end
    return x, y, z, distance
end

-- Shared admission rule for the pass snapshot and the live revalidation.
local function fleetBlocks(x, y, z, px, py, pz)
    local dx, dy, dz = x - px, y - py, z - pz
    return dx * dx + dy * dy + dz * dz < MINIMUM_SEPARATION_SQUARED
end

-- The pose separation is decided on the registry's CURRENT pose per own car,
-- not on the one-second copy the monitor keeps: a car that drove onto the
-- candidate between two monitor samples has to refuse it here as well. The
-- copy is only the fallback when the registry cannot answer for that id right
-- now; that car is retired by the monitor, and this loop must not remove its
-- bookkeeping while iterating.
local function fleetPosition(vehicleId, entry, vehicle)
    vehicle = vehicle or Open77.vehicles.get(vehicleId)
    local position = vehicle and vehicle.position
    if type(position) == "table"
        and finite(position.x) and finite(position.y) and finite(position.z) then
        return position
    end
    return entry.lastPosition
end

-- Read canonical poses once per pass, not once per candidate. Collect IDs before
-- yielding: the retirement monitor can remove entries while the scan is parked.
local function fleetSnapshot()
    local ids = {}
    for vehicleId in pairs(cars) do ids[#ids + 1] = vehicleId end
    local buckets = {}
    for index = 1, #ids do
        scanSpend(SCAN_WORK_FLEET_READ)
        local entry = cars[ids[index]]
        if entry then
            local position = fleetPosition(ids[index], entry)
            local group = buckets[entry.bucket]
            if not group then
                group = { count = 0, x = {}, y = {}, z = {} }
                buckets[entry.bucket] = group
            end
            local count = group.count + 1
            group.count = count
            group.x[count], group.y[count], group.z[count] =
                position.x, position.y, position.z
        end
    end
    return buckets
end

-- Charge inner-loop work too; a large fleet must not bypass the scan bound.
local function snapshotAllows(group, x, y, z)
    if not group then return true end
    local xs, ys, zs = group.x, group.y, group.z
    for index = 1, group.count do
        scanSpend(SCAN_WORK_COMPARISON)
        if fleetBlocks(x, y, z, xs[index], ys[index], zs[index]) then return false end
    end
    -- Each player's area budget is counted by `selectSpawn`; only the spacing
    -- applies here.
    return true
end

-- Re-read the fleet after selection/probing; snapshot poses may now be stale.
local function fleetAllowsAt(x, y, z, bucket)
    local ids = {}
    for vehicleId in pairs(cars) do ids[#ids + 1] = vehicleId end
    for index = 1, #ids do
        scanSpend(SCAN_WORK_FLEET_READ)
        local entry = cars[ids[index]]
        if entry and entry.bucket == bucket then
            local position = fleetPosition(ids[index], entry)
            if fleetBlocks(x, y, z, position.x, position.y, position.z) then return false end
        end
    end
    return true
end

-- Spawning follows the game's own crowd density
-- (docs/research/traffic-native-spawning-design.md). Each ready player owns
-- one area that leans ahead with speed. A span wants its crowd fragment's
-- coefficient times its slot count for the configured period, the coefficient
-- floored and scaled like the crowd manager does (0x2F5A2C, 0x413C60),
-- prorated by the share of its samples inside the area, less the cars matched
-- to it inside that same area: on a long span, cars outside the area must not
-- cancel the area's demand. Overlapping areas take the maximum deficit per
-- span, not the sum. An area spawns only while it holds fewer cars than it
-- wants in total, and then on the span with the largest deficit per metre of
-- the span inside the area; the spawn band, separation, quarantine and probe
-- guards then apply to the chosen sample.
local SPAN_COOLDOWN_SECONDS = 5
local SPAN_MATCH_METRES = 9
local SPAN_MATCH_HEIGHT = 3
local SPAN_MATCH_COSINE = math.cos(math.rad(45))

local function forEachSpanCell(x, y, reach, visit)
    local grid = SPANS.gridSize
    for cellX = math.floor((x - reach) / grid), math.floor((x + reach) / grid) do
        for cellY = math.floor((y - reach) / grid), math.floor((y + reach) / grid) do
            local cell = SPANS.cells[("%d:%d"):format(cellX, cellY)]
            if cell then visit(cell) end
        end
    end
end

-- The span a car is driving on: the nearest sample within half the sample
-- spacing plus lane wobble, on its road level, facing its way. Heading is what
-- keeps the opposite lane of a two-way road from being counted.
local function carSpan(position, yaw)
    if not finite(yaw) then return nil end
    local forwardX, forwardY = -math.sin(math.rad(yaw)), math.cos(math.rad(yaw))
    local best, bestSquared = nil, SPAN_MATCH_METRES * SPAN_MATCH_METRES
    forEachSpanCell(position.x, position.y, SPAN_MATCH_METRES, function(cell)
        for _, sample in ipairs(cell) do
            scanSpend(SCAN_WORK_COMPARISON)
            local dx, dy = sample[4] - position.x, sample[5] - position.y
            local squared = dx * dx + dy * dy
            if squared < bestSquared and math.abs(sample[6] - position.z) <= SPAN_MATCH_HEIGHT then
                local yawRadians = math.rad(sample[7])
                if forwardX * -math.sin(yawRadians) + forwardY * math.cos(yawRadians) >= SPAN_MATCH_COSINE then
                    best, bestSquared = sample[8], squared
                end
            end
        end
    end)
    return best
end

local function spanWanted(span, mounted)
    local base = CONFIG.timePeriod * 3
    local row = span.periods
    local coefficient = math.max(row[(mounted and 7 or 6) + base],
        mounted and CONFIG.densityFloorDriving or CONFIG.densityFloor)
    return coefficient * row[5 + base] * CONFIG.densityScale
end

-- The crowd area's lean: centre ahead by 0.3 radius and radius +20 % at full
-- lean (30 m/s), as in `CrowdVehicles_Update`.
local function leaningArea(px, py, vx, vy)
    local speed = math.sqrt(vx * vx + vy * vy)
    local lean = math.min(1, speed / 30)
    local offset = speed > 0 and CONFIG.playerAreaRadius * 0.3 * lean / speed or 0
    return px + vx * offset, py + vy * offset, CONFIG.playerAreaRadius * (1 + 0.2 * lean), speed
end

local function nativeArea(player)
    local read = Open77.players.get(player.id)
    local velocity = type(read) == "table" and read.velocity
    local vx = type(velocity) == "table" and finite(velocity.x) and velocity.x or 0
    local vy = type(velocity) == "table" and finite(velocity.y) and velocity.y or 0
    local x, y, radius = leaningArea(player.position.x, player.position.y, vx, vy)
    return {
        x = x,
        y = y,
        radius = radius,
        mounted = type(read) == "table" and read.inVehicle == true,
        player = player,
    }
end

-- Ranked spans as a binary max-heap: higher priority first, then the lower
-- span id. Every comparison is paid through scanSpend, which may yield; a
-- table.sort comparator cannot, so a sort of thousands of spans could overrun
-- the per-resume quota, and a repeated max scan costs O(n^2) when many spans
-- fail placement in a row.
local function rankedBefore(left, right)
    scanSpend(SCAN_WORK_COMPARISON)
    if left.priority ~= right.priority then return left.priority > right.priority end
    return left.spanId < right.spanId
end

local function rankedSiftDown(heap, index, size)
    while true do
        local child = index * 2
        if child > size then return end
        if child < size and rankedBefore(heap[child + 1], heap[child]) then child = child + 1 end
        if not rankedBefore(heap[child], heap[index]) then return end
        heap[index], heap[child] = heap[child], heap[index]
        index = child
    end
end

local function selectSpawn(players, refused)
    local fleet = fleetSnapshot()
    local ids = {}
    for vehicleId in pairs(cars) do ids[#ids + 1] = vehicleId end
    -- Per bucket: each own car matched to a span, with where it is.
    local matched = {}
    for index = 1, #ids do
        scanSpend(SCAN_WORK_FLEET_READ)
        local entry = cars[ids[index]]
        local vehicle = entry and Open77.vehicles.get(ids[index])
        local position = vehicle and fleetPosition(ids[index], entry, vehicle)
        local span = position and carSpan(position, vehicle.yaw)
        if span then
            local held = matched[entry.bucket] or {}
            matched[entry.bucket] = held
            held[#held + 1] = { span = span, x = position.x, y = position.y }
        end
    end

    -- Per bucket: span -> the largest deficit any open area has on it, with
    -- that area's in-area sample count and the samples its player could place
    -- a car on. An area with placeable samples wins over one without.
    local wanted = {}
    for _, player in ipairs(players) do
        local area = nativeArea(player)
        local radiusSquared = area.radius * area.radius
        local group = fleet[player.bucket]
        local present = 0
        for index = 1, group and group.count or 0 do
            scanSpend(SCAN_WORK_COMPARISON)
            local dx, dy = group.x[index] - area.x, group.y[index] - area.y
            if dx * dx + dy * dy <= radiusSquared then present = present + 1 end
        end
        if present < CONFIG.maxCarsPerArea then
            local inside = {}
            forEachSpanCell(area.x, area.y, area.radius, function(cell)
                for _, sample in ipairs(cell) do
                    scanSpend(SCAN_WORK_COMPARISON)
                    local dx, dy = sample[4] - area.x, sample[5] - area.y
                    if dx * dx + dy * dy <= radiusSquared then
                        local stat = inside[sample[8]]
                        if not stat then
                            stat = { count = 0, held = 0, samples = {} }
                            inside[sample[8]] = stat
                        end
                        stat.count = stat.count + 1
                        if candidatePlacement(sample, player) then
                            stat.samples[#stat.samples + 1] = sample
                        end
                    end
                end
            end)
            local total = 0
            for spanId, stat in pairs(inside) do
                scanSpend(SCAN_WORK_COMPARISON)
                local span = SPANS.spans[spanId]
                stat.wanted = spanWanted(span, area.mounted) * stat.count / span.samples
                total = total + stat.wanted
            end
            if present < total then
                local held = matched[player.bucket]
                for index = 1, held and #held or 0 do
                    scanSpend(SCAN_WORK_COMPARISON)
                    local car = held[index]
                    local stat = inside[car.span]
                    local dx, dy = car.x - area.x, car.y - area.y
                    if stat and dx * dx + dy * dy <= radiusSquared then stat.held = stat.held + 1 end
                end
                local bucketWanted = wanted[player.bucket] or {}
                wanted[player.bucket] = bucketWanted
                for spanId, stat in pairs(inside) do
                    scanSpend(SCAN_WORK_COMPARISON)
                    local deficit = stat.wanted - stat.held
                    local best = bucketWanted[spanId]
                    local placeable, bestPlaceable = #stat.samples > 0, best and #best.samples > 0
                    if not best or (placeable and not bestPlaceable)
                        or (placeable == bestPlaceable and deficit > best.deficit) then
                        bucketWanted[spanId] = { deficit = deficit, count = stat.count,
                            samples = stat.samples, player = player }
                    end
                end
            end
        end
    end

    -- Best first through a heap (see rankedBefore): O(n) to build, O(log n)
    -- per span tried; the first allowed sample ends the pass.
    local now = Open77.time.monotonic()
    local ranked = {}
    for bucket, spans in pairs(wanted) do
        local runtime = corridorRuntime(bucket)
        for spanId, want in pairs(spans) do
            scanSpend(SCAN_WORK_COMPARISON)
            if want.deficit > 0 and #want.samples > 0
                and not ((runtime.spanCooldownUntil[spanId] or 0) > now) then
                local span = SPANS.spans[spanId]
                ranked[#ranked + 1] = { spanId = spanId, runtime = runtime, want = want,
                    priority = want.deficit / (span.length * want.count / span.samples) }
            end
        end
    end

    local size = #ranked
    for index = size // 2, 1, -1 do rankedSiftDown(ranked, index, size) end
    while size > 0 do
        local choice = ranked[1]
        ranked[1] = ranked[size]
        ranked[size] = nil
        size = size - 1
        rankedSiftDown(ranked, 1, size)
        local runtime, player, samples = choice.runtime, choice.want.player, choice.want.samples
        local start = nextRandom(#samples)
        for step = 0, #samples - 1 do
            scanSpend(SCAN_WORK_CANDIDATE)
            local sample = samples[(start + step - 1) % #samples + 1]
            local key = -sample[1]
            if not ((refused[runtime] and refused[runtime][key]) or runtime.use[key]
                or rejectedCorridors[key] or corridorQuarantined(runtime, key)
                or laneQuarantined(runtime, laneKey(sample)))
                and snapshotAllows(fleet[player.bucket], sample[4], sample[5], sample[6]) then
                local _, _, _, distance = candidatePlacement(sample, player)
                return {
                    corridorIndex = key,
                    runtime = runtime,
                    corridor = sample,
                    anchor = corridorAnchor(sample),
                    player = player,
                    distance = distance,
                    spanId = choice.spanId,
                }
            end
        end
    end
    return nil
end

-- No reservation yet. Revalidate both the winner and its current admission gates.
local function selectionStillValid(selection, refused)
    local corridorIndex = selection.corridorIndex
    local runtime = selection.runtime
    local x, y, z = corridorPoint(selection.corridor)
    if not fleetAllowsAt(x, y, z, selection.player.bucket) then return nil end
    if (refused[runtime] and refused[runtime][corridorIndex]) or runtime.use[corridorIndex]
        or rejectedCorridors[corridorIndex] or corridorQuarantined(runtime, corridorIndex)
        or laneQuarantined(runtime, laneKey(selection.corridor)) then
        return nil
    end
    local player = currentPlayerAnchor(selection.player.id)
    if not player or player.bucket ~= selection.player.bucket then return nil end
    if not admissionAvailable(player.id) then return nil end
    local _, _, _, d = candidatePlacement(selection.corridor, player)
    if not d then return nil end
    return player
end

-- Check again after every suspending step, without charging obsolete ground
-- replies as corridor failures. A moved generation is checked first: a reset or
-- a settings change while this pass was parked invalidates the selection, the
-- corridor reservation and the admission it was made under, and the car must
-- not be created on the far side of it.
local function attemptStillValid(selection, passGeneration)
    if passGeneration ~= generation then
        return nil, "the fleet or its settings changed while this pass was parked"
    end
    if rejectedCorridors[selection.corridorIndex] then
        return nil, "the candidate was quarantined"
    end
    local player = currentPlayerAnchor(selection.player.id)
    if not player then return nil, "the selecting player is no longer ready and alive" end
    if player.bucket ~= selection.player.bucket then
        return nil, "the selecting player changed bucket"
    end
    if not admissionAvailable(player.id) then return nil, "simulator admission is full" end
    local _, _, _, d = candidatePlacement(selection.corridor, player)
    if not d then return nil, "the selecting player left the spawn band" end
    return player
end

-- Frees the car's spawn spot if the car still holds it: a spot freed once its
-- car drove off may already hold the next car, which this must not release.
local function releaseCorridor(entry, vehicleId)
    if entry and entry.corridorIndex and entry.runtime.use[entry.corridorIndex] == vehicleId then
        entry.runtime.use[entry.corridorIndex] = nil
    end
end

-- Stops whatever AI the car still has and takes this resource's own driver NPC
-- out of the world. Both driving calls are best-effort: the driving service ends
-- a destroyed car's task itself -- keeping a seated driver's job attached (see
-- WRECK_DEATH_GRACE_SECONDS) and detaching one without a driver -- so
-- `stop`/`removeDriver` may answer `driver_not_attached` without changing anything. The NPC removal is
-- the part that must not be skipped -- nothing else in the world owns that ped
-- -- and it is the one answer this returns: whether a driver was really
-- removed, so a caller that reports what it did can report that too.
local function releaseDriver(vehicleId, entry)
    Open77.vehicles.ai.stop(vehicleId)
    Open77.vehicles.ai.removeDriver(vehicleId)
    if entry.driverId then return Open77.npcs.remove(entry.driverId) == true end
    return false
end

-- Drops the resource's own bookkeeping for a car it no longer owns: the
-- corridor reservation is released with the entry, so a car that leaves the
-- fleet never leaks its candidate for the rest of the resource run.
local function releaseTracking(vehicleId, entry)
    cars[vehicleId] = nil
    if entry.driverId and driverCars[entry.driverId] == vehicleId then driverCars[entry.driverId] = nil end
    releaseCorridor(entry, vehicleId)
end

local function removePair(vehicleId, entry)
    releaseDriver(vehicleId, entry)
    Open77.vehicles.remove(vehicleId)
    releaseTracking(vehicleId, entry)
end

local function playerOccupied(vehicle)
    return vehicle and type(vehicle.occupants) == "table" and #vehicle.occupants > 0
end

-- The canonical ledger's own answer to "is this car a wreck": Destroyed or
-- Exploded, either flag, or health at zero. It is read from the vehicle record,
-- never inferred from the task state, because a destroyed car's task is gone
-- before this loop looks at it: `task_missing` is what a wreck and a vanished
-- task both look like, and only the record can tell them apart.
local function vehicleWrecked(vehicle)
    if not vehicle then return false end
    if vehicle.destroyed == true or vehicle.exploded == true then return true end
    return finite(vehicle.health) and vehicle.health <= 0
end

-- Ambient drivers are civilians players can kill unless `driversKillable` is
-- off (see `driverDamagePolicy` and the create in `spawnOne`). A killed
-- driver stays in its seat: the driving service keeps its job attached, so the
-- body stays mounted, slumped, on every client and the seat stays reserved
-- until a player steals the car and drags the body out. `sweepCorpses` removes
-- a seated body only with its car. Once it is out, it is removed
-- CORPSE_MAXIMUM_SECONDS after the drag-out at the latest, sooner once no
-- player of its bucket has been inside its streaming window for
-- CORPSE_UNOBSERVED_SECONDS, and at once when its car is gone.
local CORPSE_UNOBSERVED_SECONDS = 10
local CORPSE_MAXIMUM_SECONDS = 60

-- `VehicleAuthorityService.StreamOutRadius`: a player's client keeps a car
-- loaded until it is this far away, so past it from every player of its bucket
-- nobody can see the car any more.
local STREAM_OUT_METRES = 425

-- A car the crowd area has left behind is released, as the crowd
-- manager does, instead of keeping it on its simulator's slots until 425 m:
-- at 160 km/h a car the driver passed held one of their 32 slots for ~13 s and
-- then waited 10 s ownerless. Eligible only when it is outside every player's
-- leaning area AND every player who could have it streamed (within 425 m) is
-- moving at least NATIVE_FORWARD_ONLY_SPEED away from it -- a slow or standing
-- viewer always keeps it, and a car beside or ahead of anyone is never touched.
-- The server cannot see a camera, so this is the one removal that accepts a
-- car vanishing behind a fast driver. A viewer within 425 m whose pose is
-- older than NATIVE_TRAIL_FRESH_MS (or undated) may have stopped or turned
-- back since, so they keep the car like a slow viewer.
local NATIVE_TRAIL_SECONDS = 2
local NATIVE_TRAIL_FRESH_MS = 500
local function trailingCar(position, bucket, positions)
    local trailing = false
    for _, viewer in pairs(positions) do
        if (viewer.bucket or 0) == bucket and finite(viewer.x) and finite(viewer.y) then
            local velocity = viewer.velocity
            local vx = type(velocity) == "table" and finite(velocity.x) and velocity.x or 0
            local vy = type(velocity) == "table" and finite(velocity.y) and velocity.y or 0
            local cx, cy, radius, speed = leaningArea(viewer.x, viewer.y, vx, vy)
            local ax, ay = position.x - cx, position.y - cy
            if ax * ax + ay * ay <= radius * radius then return false end
            local dx, dy = position.x - viewer.x, position.y - viewer.y
            if dx * dx + dy * dy <= STREAM_OUT_METRES * STREAM_OUT_METRES then
                if speed < NATIVE_FORWARD_ONLY_SPEED or dx * vx + dy * vy >= 0
                    or not finite(viewer.ageMs) or viewer.ageMs > NATIVE_TRAIL_FRESH_MS then
                    return false
                end
                trailing = true
            end
        end
    end
    return trailing
end

-- Unknown observation is not evidence that a body is hidden. In addition to
-- dated positions, consult the authoritative interest ledger: a stale player's
-- projection remains streamed until the server explicitly removes it.
local function observedWithin(point, reach, positions)
    local bucket = point.bucket or 0
    point = point.position or point
    if type(positions) ~= "table" or not finite(point.x) or not finite(point.y) or not finite(point.z) then
        return true
    end
    for _, position in pairs(positions) do
        if type(position) == "table" and (position.bucket or 0) == bucket
            and finite(position.x) and finite(position.y) and finite(position.z) then
            local dx, dy, dz = position.x - point.x, position.y - point.y, position.z - point.z
            if dx * dx + dy * dy + dz * dz <= reach * reach then return true end
        end
    end
    return false
end

local function vehicleObserved(vehicleId, vehicle, positions)
    if observedWithin(vehicle, STREAM_OUT_METRES, positions) then return true end
    for id in pairs(positions) do
        if Open77.vehicles.isVisibleTo(vehicleId, id) ~= false then return true end
    end
    return false
end

-- A car whose impact recovery failed, or whose native join was interrupted
-- after it had been running (the engine dropped the command, e.g. pinned
-- against another car after a crash), stays stalled in view while a join can
-- still recover it. Retry at most twelve times; an unrecoverable simulator
-- failure or exhausted retries ends recovery, but keeps the car and driver
-- while observed. Continuous absence permits their eventual removal.
local STALLED_UNOBSERVED_SECONDS = 10
local STALLED_RETRY_SECONDS = 5
local STALLED_RETRY_LIMIT = 12

-- The server reports any dropped native command as `native_command_failed`.
-- Within JOIN_FAILURE_SECONDS of the create it is a spot that cannot join and
-- goes to `retire`, where `noteJoinOutcome` benches the corridor; later, it is
-- a running car the engine interrupted.
local function interruptedJoin(entry, state, now)
    return state.reason == "native_command_failed" and entry.spawnedAt ~= nil
        and now - entry.spawnedAt > JOIN_FAILURE_SECONDS
end

-- The driving service keeps a wreck's seated driver attached instead of freeing
-- the seat. The explosion that wrecked the car usually kills that driver too,
-- but the kill is reported by the shooter's client and can land after the wreck:
-- a wreck's disposition waits this long for it, so a driver about to be declared
-- dead stays seated in the wreck (see `keepCorpse`) instead of being removed.
local WRECK_DEATH_GRACE_SECONDS = 2

-- A spawn spot is held by its car only while the car is still on it. Held for
-- the car's whole life, a spot near a standing player produced one car a minute
-- (reused a median 0.1 s after its car retired); once the car is this far from
-- it the spot takes the next car, and the 20 m clearance guard still keeps one
-- from being created on a car that has not left.
local SPOT_RELEASE_METRES = 30

-- The canonical NPC registry's own answer to "was this driver killed": the ped
-- still exists and its health is zero. It is read from the record, never from
-- the task: the driving service ends a killed driver's task as `driver_dead`
-- on its own next tick and detaches it when the seat is stolen, so the monitor
-- can meet a dead driver whose task is still running, already failed, or gone.
local function driverKilled(entry)
    if not entry.driverId then return false end
    local npc = Open77.npcs.get(entry.driverId)
    return type(npc) == "table" and finite(npc.health) and npc.health <= 0
end

-- A death announcement's source or cause, bounded to a log token.
local function deathToken(value)
    return (tostring(value or ""):match("^[%w_:%.%-]+") or "unknown"):sub(1, 64)
end

-- Hands a killed driver's body to the corpse sweep. The ped is neither removed
-- nor moved and its task is not touched: the driving service already ended it
-- and keeps the body seated until the seat is stolen, and a stop or detach from
-- here would unseat it and overwrite `driver_dead` with a cause of its own.
local function keepCorpse(vehicleId, entry)
    local death = entry.death or {}
    corpses[entry.driverId] = {
        vehicleId = vehicleId,
        releasedAt = Open77.time.monotonic(),
        source = death.source or "unknown",
        cause = death.cause or "unknown",
    }
end

-- Who or what killed a driver, as the NPC registry announces it to every
-- resource. It only annotates: the monitor decides from the record itself,
-- because this announcement and the monitor's tick can arrive in either
-- order, and a late one still names the cause of a body already kept.
AddEventHandler("onNpcDied", function(npcId, source, cause)
    local driverId = math.tointeger(tonumber(npcId))
    if not driverId then return end
    local death = { source = deathToken(source), cause = deathToken(cause) }
    local vehicleId = driverCars[driverId]
    local entry = vehicleId and cars[vehicleId]
    if entry then
        entry.death = death
        return
    end
    local corpse = corpses[driverId]
    if corpse and corpse.cause == "unknown" then corpse.source, corpse.cause = death.source, death.cause end
end)

-- A car whose join failed within JOIN_FAILURE_SECONDS of its create says its
-- spot cannot put a car into traffic: measured, one spawn point failed
-- 900 of 901 spawns, each 2.9 s after the create, and being released without a
-- quarantine it was chosen again every ~3 s. That many in a
-- row bench the corridor like ground failures do; any other end of a car from
-- it clears the count.
local function noteJoinOutcome(entry, reason)
    local runtime, index = entry.runtime, entry.corridorIndex
    if not runtime or not index then return end
    if reason ~= "native_command_failed" or not entry.spawnedAt
        or Open77.time.monotonic() - entry.spawnedAt > JOIN_FAILURE_SECONDS then
        runtime.joinFailures[index] = nil
        return
    end
    local failures = (runtime.joinFailures[index] or 0) + 1
    if failures < JOIN_FAILURE_LIMIT then
        runtime.joinFailures[index] = failures
        return
    end
    runtime.joinFailures[index] = nil
    runtime.quarantineUntil[index] = Open77.time.monotonic() + CORRIDOR_QUARANTINE_SECONDS
    log("quarantined corridor %s for %d s after %d join failures right after spawn",
        entry.corridorName, CORRIDOR_QUARANTINE_SECONDS, failures)
end

-- A car knocked out of traffic within IMPACT_FAILURE_SECONDS of its create
-- counts against its source lane, not its anchor: measured, 7 of 9 stalled
-- cars in one run came from three anchors of one lane climbing a ramp into a
-- merge, each crashing 20-60 s after the create and held at the top by the
-- stalled retry, so benching the one anchor only moved the next car to its
-- neighbour.
local function noteImpactFailure(entry, now)
    local runtime, lane = entry.runtime, entry.laneKey
    if not runtime or not lane or not entry.spawnedAt
        or now - entry.spawnedAt > IMPACT_FAILURE_SECONDS or laneQuarantined(runtime, lane) then
        return
    end
    local failures = runtime.impactFailures[lane]
    if not failures or now - failures.since > IMPACT_FAILURE_WINDOW_SECONDS then
        failures = { count = 0, since = now }
        runtime.impactFailures[lane] = failures
    end
    failures.count = failures.count + 1
    if failures.count < IMPACT_FAILURE_LIMIT then return end
    runtime.impactFailures[lane] = nil
    runtime.laneQuarantineUntil[lane] = now + CORRIDOR_QUARANTINE_SECONDS
    log("quarantined lane %s for %d s after %d impact failures right after spawn (corridor %s)",
        tostring(lane), CORRIDOR_QUARANTINE_SECONDS, failures.count, entry.corridorName)
end

local function retire(vehicleId, reason, unownable, trailing)
    local entry = cars[vehicleId]
    if not entry then return end
    if not entry.retirementNoted then
        noteJoinOutcome(entry, reason)
        entry.retirementNoted = true
    end
    local vehicle = Open77.vehicles.get(vehicleId)
    -- The monitor names a killed driver `driver_dead` from the NPC record. That
    -- car's task is the driving service's to end, and it has: see `keepCorpse`.
    local killed = reason == "driver_dead"
    -- Wreck retention. A destroyed car is not deleted: the resource stops its
    -- AI, removes its driver NPC and releases the corridor, then hands the body
    -- to the canonical registry as an ordinary unobserved-despawn vehicle. It
    -- is deliberately NOT persistent -- a wreck somebody can still see, or is
    -- sitting in, stays until nobody has had it streamed for the registry's own
    -- thirty-second grace, which is bounded UNOBSERVED time and not a hard
    -- time-to-live. Occupied live cars use the same bounded disposition. A
    -- killed driver of a wreck is kept as a corpse instead of being removed.
    if vehicleWrecked(vehicle) then
        if killed then keepCorpse(vehicleId, entry) else releaseDriver(vehicleId, entry) end
        Open77.vehicles.setPersistent(vehicleId, false)
        Open77.vehicles.setDespawnWhenUnobserved(vehicleId, true)
        releaseTracking(vehicleId, entry)
        log("retained wreck reason=%s car=%s profile=%s",
            reason, tostring(vehicleId), entry.profileName)
        return
    end
    -- A killed driver's healthy car is the same canonical car for whoever takes
    -- it: never deleted, replaced or given another driver. It leaves the ambient
    -- ledger -- its corridor is released, and neither the road nor the profile
    -- is held against a death -- and is handed to the registry's bounded
    -- unobserved cleanup exactly as an occupied car is, so a player aboard or
    -- anyone who still has it streamed keeps it, and nobody at all for thirty
    -- seconds removes it. Occupants already aboard stay where they are.
    if killed then
        keepCorpse(vehicleId, entry)
        Open77.vehicles.setPersistent(vehicleId, false)
        Open77.vehicles.setDespawnWhenUnobserved(vehicleId, true)
        releaseTracking(vehicleId, entry)
        local corpse = corpses[entry.driverId]
        log("released killed-driver car %s driver=%s cause=%s source=%s profile=%s",
            tostring(vehicleId), tostring(entry.driverId), corpse.cause, corpse.source, entry.profileName)
        return
    end
    if playerOccupied(vehicle) then
        releaseDriver(vehicleId, entry)
        Open77.vehicles.setPersistent(vehicleId, false)
        Open77.vehicles.setDespawnWhenUnobserved(vehicleId, true)
        releaseTracking(vehicleId, entry)
        log("released reason=%s car=%s profile=%s",
            reason, tostring(vehicleId), entry.profileName)
        return
    end
    -- Transient ownership loss and exhausted retries are not permission to
    -- erase a visible car (or its seated driver). Keeping it in the bounded
    -- fleet ledger also prevents each failure from spawning a replacement on
    -- top of the retained fleet. A healthy job can still regain its simulator.
    -- Except when the driving service says no viewer may simulate it: the
    -- election only grants inside the stream-in radius, while a car stays
    -- streamed out to the larger stream-out radius, so a car between the two
    -- would otherwise stay frozen in view until everyone leaves, and every
    -- such car came back into physics at once when a player returned.
    -- And except a car the crowd area left behind a fast driver: the monitor
    -- already required NATIVE_TRAIL_SECONDS of it (see `trailingCar`), and the
    -- point of that rule is to release it while it is still streamed.
    local bypass = unownable or trailing
    if not bypass and vehicleObserved(vehicleId, vehicle, observationPositions()) then
        entry.retireUnobservedSince = nil
        return
    end
    local now = Open77.time.monotonic()
    entry.retireUnobservedSince = entry.retireUnobservedSince or entry.unobservedSince
        or entry.stalledUnobservedSince or now
    if not bypass and now - entry.retireUnobservedSince < UNOBSERVED_GRACE_SECONDS then return end
    removePair(vehicleId, entry)
    log("retired reason=%s car=%s profile=%s%s", reason, tostring(vehicleId), entry.profileName,
        unownable and " unownable=1" or "")
end

-- The final placement guard, evaluated at the EXACT create point -- the
-- post-probe ground height plus the chassis lift, not the catalog anchor --
-- with no scheduler yield between this call and the create it authorises.
--
-- It reads the canonical same-bucket proximity query, which sees every
-- registered vehicle: this resource's own cars, freeroam/player deliveries,
-- adopted cars and other resources' AI vehicles. The only accepted answer is
-- an empty table. A non-empty table blocks whatever it holds, and a refused,
-- nil or malformed response is not evidence the point is free, so it defers
-- the whole attempt instead.
--
-- This is a conservative CENTRE exclusion, not a body-shape or footprint
-- claim: the registry carries no vehicle bounds, so the radius is the whole
-- test, and a car on another deck inside it is a conservative refusal rather
-- than a precise overlap result.
local function clearanceState(spawnPoint, bucket)
    local found, reason = Open77.vehicles.nearby(spawnPoint, SPAWN_CLEARANCE_RADIUS, {
        bucket = bucket,
        limit = 1,
    })
    if type(found) ~= "table" then
        return "unavailable", ("query unavailable (%s)"):format(tostring(reason))
    end
    local entry = found[1]
    if entry == nil then
        if next(found) == nil then return "clear" end
        return "blocked", "occupied by an unidentified vehicle"
    end
    if type(entry) == "table" and finite(entry.distance) then
        return "blocked", ("occupied by %s at %.1f m"):format(tostring(entry.id), entry.distance)
    end
    return "blocked", "occupied by an unidentified vehicle"
end

-- Every recently seen player excludes spawning, including a dead or temporarily
-- omitted player. These dated points never select a simulator or renew authority.
-- The horizontal column also protects players on a different road deck. Check
-- both before the probe and again at the exact create point, without yielding.
-- Players in another bucket never block. A roster that cannot be read is not
-- evidence the point is free, so it defers the attempt.
local function playerExclusionState(x, y, bucket)
    local positions = observationPositions()
    if type(positions) ~= "table" then return "unavailable" end
    for _, position in pairs(positions) do
        if type(position) == "table" and (position.bucket or 0) == bucket
            and finite(position.x) and finite(position.y) then
            local dx, dy = x - position.x, y - position.y
            if dx * dx + dy * dy < PLAYER_EXCLUSION_SQUARED then
                return "blocked"
            end
            -- Cover the player's approach during resource delivery and native
            -- attachment. A point 60 m ahead of a fast car is not a safe spawn
            -- just because it was clear at the server's creation instant.
            local velocity = position.velocity
            if type(velocity) == "table" and finite(velocity.x) and finite(velocity.y) then
                local age = finite(position.ageMs) and math.min(2, math.max(0, position.ageMs / 1000)) or 0
                -- 1.5 s still covers the ~1 s a new car takes to appear on
                -- clients; 3 s at 160 km/h left only ~190-250 m ahead, where
                -- client ground probes still succeed.
                local horizon = 1.5 + age
                local vx, vy = velocity.x * horizon, velocity.y * horizon
                local lengthSquared = vx * vx + vy * vy
                if lengthSquared > 0 then
                    local fraction = math.max(0, math.min(1, (dx * vx + dy * vy) / lengthSquared))
                    local gapX, gapY = dx - vx * fraction, dy - vy * fraction
                    if gapX * gapX + gapY * gapY < PLAYER_EXCLUSION_SQUARED then return "blocked" end
                end
            end
        end
    end
    return "clear"
end

-- A placement failure skips the whole span for the span cooldown, as the
-- crowd manager does. Without it the highest-deficit span -- typically a short
-- one where cars queue at a light, so every sample fails clearance -- wins every
-- pass and starves the rest of the area.
local NATIVE_GROUND_EVIDENCE_METRES = 150
local function holdSpan(selection)
    selection.runtime.spanCooldownUntil[selection.spanId] = Open77.time.monotonic() + SPAN_COOLDOWN_SECONDS
end

-- A new car starts moving along its lane, as the crowd system's
-- traffic stubs already are when their entity appears, instead of from rest.
-- The speed is capped so the car could stop before the nearest vehicle ahead
-- on its heading. The query does not yield, so it is read at the create.
local LAUNCH_BRAKING = 3
local LAUNCH_MARGIN_METRES = 12
local LAUNCH_LOOKAHEAD_METRES = 80
local LAUNCH_LANE_HALF_WIDTH = 4
local function launchVelocity(point, yaw, bucket)
    if CONFIG.launchSpeed <= 0 or not finite(yaw) then return nil end
    local forwardX, forwardY = -math.sin(math.rad(yaw)), math.cos(math.rad(yaw))
    local found = Open77.vehicles.nearby(point, LAUNCH_LOOKAHEAD_METRES, { bucket = bucket, limit = 32 })
    if type(found) ~= "table" then return nil end
    local free = LAUNCH_LOOKAHEAD_METRES
    for _, other in ipairs(found) do
        local position = type(other) == "table" and other.position
        if type(position) == "table" and finite(position.x) and finite(position.y) then
            local dx, dy = position.x - point.x, position.y - point.y
            local ahead = dx * forwardX + dy * forwardY
            if ahead > 0 and math.abs(dx * forwardY - dy * forwardX) < LAUNCH_LANE_HALF_WIDTH then
                free = math.min(free, ahead)
            end
        end
    end
    local speed = math.min(CONFIG.launchSpeed,
        math.sqrt(2 * LAUNCH_BRAKING * math.max(0, free - LAUNCH_MARGIN_METRES)))
    if speed < 1 then return nil end
    return { x = forwardX * speed, y = forwardY * speed, z = 0 }
end

local function spawnOne(players)
    -- A candidate the final clearance refuses is dropped from this selection
    -- pass and the next-best candidate is tried, so a car parked on the
    -- nearest candidate cannot starve the whole candidate set. The refusal is
    -- NOT remembered past the pass: the corridor reservation is released
    -- here and the candidate is eligible again on the next spawn tick.
    --
    -- The generation this pass was opened under travels with it: the scan
    -- yields, the ground probe yields, and a reset or a settings change that
    -- lands in either gap must not be able to see this pass create a car
    -- afterwards.
    local passGeneration = generation
    local refused = {}
    local selection, corridor, anchor, name, spawnZ, groundZ
    for _ = 1, CONFIG.clearanceAttempts do
        -- Earlier attempts may have suspended.
        if passGeneration ~= generation then return false end
        if remainingNpcCapacity() <= 0 then return false end
        local anchors = {}
        local capacity = Open77.vehicles.ai.capacity()
        for _, player in ipairs(refreshAnchors(players)) do
            if admissionAvailable(player.id, capacity) then anchors[#anchors + 1] = player end
        end
        if #anchors == 0 then return false end
        selection = selectSpawn(anchors, refused)
        if not selection then return false end
        if passGeneration ~= generation then
            -- The scan itself suspended. Nothing is reserved yet.
            return false
        end

        corridor = selection.corridor
        anchor = selection.anchor
        name = corridorName(corridor)

        local player = selectionStillValid(selection, refused)
        -- The selection/fleet walk can yield before any reservation is made.
        if remainingNpcCapacity() <= 0 then return false end
        local bucketRefused = refused[selection.runtime]
        if not bucketRefused then
            bucketRefused = {}
            refused[selection.runtime] = bucketRefused
        end
        bucketRefused[selection.corridorIndex] = true
        local precheckState
        if player then
            selection.player = player
            selection.runtime.use[selection.corridorIndex] = true

            if passGeneration ~= generation then
                selection.runtime.use[selection.corridorIndex] = nil
                return false
            end

            -- Cheap server-local filter first: a point the registry already
            -- shows occupied, or a player already stands on, is refused
            -- without paying a client raycast. It does not yield. The final
            -- check below stays authoritative, because the probe yields and
            -- the fleet and the players can move meanwhile.
            precheckState = clearanceState(
                { x = anchor.x, y = anchor.y, z = anchor.z + CONFIG.spawnLiftMetres }, player.bucket)
            if precheckState == "clear" then
                precheckState = playerExclusionState(anchor.x, anchor.y, player.bucket)
            end
        end
        if not player then
            -- Nothing is reserved; retry with fresh player rows.
            selection = nil
        elseif precheckState ~= "clear" then
            selection.runtime.use[selection.corridorIndex] = nil
            holdSpan(selection)
            selection = nil
            deferrals.precheck = deferrals.precheck + 1
            if precheckState == "unavailable" then return false end
        else
            local groundDetail
            groundZ, groundDetail = Open77.world.groundZ(anchor, {
                playerId = player.id,
                cache = false,
                fromZ = anchor.z + 1.5,
            })
            -- An obsolete reply must neither place a car nor quarantine its anchor.
            local stale
            player, stale = attemptStillValid(selection, passGeneration)
            if not player then
                selection.runtime.use[selection.corridorIndex] = nil
                log("deferred corridor %s after an obsolete ground reply (%s)", name, tostring(stale))
                return false
            end
            -- A planar lane match cannot distinguish stacked road decks. Keep
            -- the collision surface in the catalogue's authored road level.
            if groundZ and (not finite(groundZ) or math.abs(groundZ - anchor.z) > 1.5) then
                groundDetail = "road_level_mismatch"
                groundZ = nil
            end
            if not groundZ then
                selection.runtime.use[selection.corridorIndex] = nil
                holdSpan(selection)
                -- Far from its player the sector may simply not be streamed
                -- yet; that says nothing about the road, so only the span hold
                -- applies.
                if selection.distance > NATIVE_GROUND_EVIDENCE_METRES then
                    deferrals.groundMiss = deferrals.groundMiss + 1
                    return false
                end
                local failures = (selection.runtime.groundFailures[selection.corridorIndex] or 0) + 1
                selection.runtime.groundFailures[selection.corridorIndex] = failures
                if failures >= CONFIG.groundFailureLimit then
                    selection.runtime.groundFailures[selection.corridorIndex] = nil
                    selection.runtime.quarantineUntil[selection.corridorIndex] = Open77.time.monotonic() + CORRIDOR_QUARANTINE_SECONDS
                    log("quarantined corridor %s for %d s after %d close-range ground query failures (%s)",
                        name, CORRIDOR_QUARANTINE_SECONDS, failures, tostring(groundDetail))
                else
                    deferrals.groundMiss = deferrals.groundMiss + 1
                end
                return false
            end
            selection.runtime.groundFailures[selection.corridorIndex] = nil
            spawnZ = groundZ + CONFIG.spawnLiftMetres

            -- The probe suspended. Recheck live fleet admission at the create height.
            if not fleetAllowsAt(anchor.x, anchor.y, spawnZ, player.bucket) then
                selection.runtime.use[selection.corridorIndex] = nil
                holdSpan(selection)
                deferrals.fleetMoved = deferrals.fleetMoved + 1
                return false
            end
            -- The fleet walk can suspend too. No yields from here to create.
            player, stale = attemptStillValid(selection, passGeneration)
            if not player then
                selection.runtime.use[selection.corridorIndex] = nil
                log("deferred corridor %s before the create (%s)", name, tostring(stale))
                return false
            end
            selection.player = player
            if remainingNpcCapacity() <= 0 then
                selection.runtime.use[selection.corridorIndex] = nil
                return false
            end

            -- Clearance and create must be one uninterrupted stretch.
            local spawnPoint = { x = anchor.x, y = anchor.y, z = spawnZ }
            local state = clearanceState(spawnPoint, player.bucket)
            if state == "clear" then state = playerExclusionState(spawnPoint.x, spawnPoint.y, player.bucket) end
            if state == "clear" then break end

            selection.runtime.use[selection.corridorIndex] = nil
            holdSpan(selection)
            selection = nil
            deferrals.clearance = deferrals.clearance + 1
            if state == "unavailable" then return false end
        end
    end
    if not selection then return false end
    local launch = launchVelocity(
        { x = anchor.x, y = anchor.y, z = spawnZ }, anchor.yaw, selection.player.bucket)

    local profileIndex, profile = selectPopulation()
    if not profile then
        selection.runtime.use[selection.corridorIndex] = nil
        rejectedCorridors[selection.corridorIndex] = true
        log("rejected corridor %s because no qualified population pairing remains for this resource run",
            name)
        return false
    end

    local vehicleId
    local driverId
    -- One look per car, drawn once here from the existing seeded generator and
    -- carried by the canonical create, so every viewer and every stream-in
    -- replays the same variant instead of letting each client's engine draw
    -- its own. The engine's stock variant already carries the colour, so no
    -- paint override is authored.
    local vehicleAppearance =
        profile.vehicleAppearances[nextRandom(#profile.vehicleAppearances)]
    local driverAppearance =
        profile.driverAppearances[nextRandom(#profile.driverAppearances)]
    local failureStage = "vehicle_create"
    local ok, failure = pcall(function()
        vehicleId = assert(Open77.vehicles.create({
            record = profile.vehicleRecord,
            appearance = vehicleAppearance,
            position = { x = anchor.x, y = anchor.y, z = spawnZ },
            yaw = anchor.yaw,
            bucket = selection.player.bucket,
            -- Created with the lock in force, so a car spawned while stealing
            -- is off is never enterable, not even for one publication.
            flags = CONFIG.carsStealable and 0 or Open77.vehicles.flags.locked,
        }))
        -- NPC mounting cannot toggle a replicated vehicle's electrical state.
        -- Author ignition before handing the car to the native traffic agent.
        failureStage = "vehicle_ignition"
        assert(Open77.vehicles.setEngine(vehicleId, true))
        failureStage = "vehicle_freeze"
        assert(Open77.vehicles.setFrozen(vehicleId, true))
        failureStage = "npc_create"
        driverId = assert(Open77.npcs.create({
            record = profile.driverRecord,
            appearance = driverAppearance,
            position = { x = anchor.x, y = anchor.y, z = spawnZ },
            yaw = anchor.yaw,
            bucket = selection.player.bucket,
            aiMode = Open77.npcs.ai.frozen,
            -- Mortal while drivers are killable: an ambient driver is then a
            -- civilian a player can kill. `create` defaults every NPC to
            -- `immortal` (health floored at 1 and the projected body shielded
            -- from death), which is right for scripted characters; the frozen AI
            -- mode above is about who drives the body, not whether it can die. A
            -- killed driver ends its task as `driver_dead` and stays in its seat
            -- until a player steals the car (see `keepCorpse`).
            damagePolicy = driverDamagePolicy(),
            behavior = {
                aiEnabled = false,
                combatEnabled = false,
                perceptionEnabled = false,
                voiceEnabled = false,
            },
        }))
        failureStage = "attach_driver"
        assert(Open77.vehicles.ai.attachDriver(vehicleId, {
            npcId = driverId, admissionPlayerId = selection.player.id,
        }))
        failureStage = "join_traffic"
        -- One submission per car. The join command enrolls the car in the
        -- engine's own traffic simulation and runs until the bounded task
        -- deadline, a failure, or retirement; only a stalled car's join is
        -- re-submitted (see STALLED_*). The reason is asserted, not
        -- swallowed: a refused option must name itself.
        local joined, joinReason = Open77.vehicles.ai.joinTraffic(vehicleId, {
            timeoutMilliseconds = CONFIG.timeoutMilliseconds,
        })
        assert(joined, joinReason)
        failureStage = "vehicle_unfreeze"
        assert(Open77.vehicles.setFrozen(vehicleId, false))
        -- After the thaw: a frozen car is pinned at rest. A refusal leaves the
        -- car starting from rest, which is what it did before.
        if launch then
            local launched, refusal = Open77.vehicles.setLaunchVelocity(vehicleId, launch)
            if not launched then
                log("car %s starts from rest: launch velocity refused (%s)", tostring(vehicleId), tostring(refusal))
            end
        end
    end)

    if not ok then
        if driverId then Open77.npcs.remove(driverId) end
        if vehicleId then Open77.vehicles.remove(vehicleId) end
        selection.runtime.use[selection.corridorIndex] = nil
        -- Capacity is temporary, not evidence of a bad profile or spawn point.
        -- assert() prefixes the API's error code with its source location.
        local code = tostring(failure):match("([^%s:]+)%s*$")
        if code == "vehicle_limit" or code == "npc_limit"
            or code == "npc_resource_limit" or code == "ai_simulator_limit" then
            log("deferred corridor %s at %s: %s", name, failureStage, code)
            Wait(1000)
            return false
        end
        if failureStage == "vehicle_create" or failureStage == "npc_create" then
            rejectedProfiles[profileIndex] = true
            log("rejected profile %s for this resource run at %s: %s",
                profile.name, failureStage, tostring(failure))
        else
            -- A task/driver lifecycle refusal says nothing about road geometry.
            log("deferred corridor %s at %s: %s", name, failureStage, tostring(failure))
            Wait(1000)
        end
        return false
    end

    cars[vehicleId] = {
        corridorIndex = selection.corridorIndex,
        laneKey = laneKey(corridor),
        runtime = selection.runtime,
        corridorName = name,
        profileName = profile.name,
        driverId = driverId,
        bucket = selection.player.bucket,
        lastPosition = { x = anchor.x, y = anchor.y, z = groundZ },
        orphanSeconds = 0,
        neverOwnedSeconds = 0,
        hadOwner = false,
        lastEpoch = 0,
        spawnedAt = Open77.time.monotonic(),
        spawnPosition = { x = anchor.x, y = anchor.y },
    }
    selection.runtime.use[selection.corridorIndex] = vehicleId
    holdSpan(selection)
    driverCars[driverId] = vehicleId
    log("spawned car %s on corridor %s profile %s vehicle %s (%s) driver %s (%s)",
        tostring(vehicleId), name, profile.name, profile.vehicleRecord, vehicleAppearance,
        profile.driverRecord, driverAppearance)
    return true
end

CreateThread(function()
    while not stopping do
        -- A reset is deleting the fleet this thread would replenish, and it
        -- yields between chunks: creation stays blocked for its whole duration
        -- rather than racing the deletion.
        if not resetting and CONFIG.enabled then
            local players = activePlayers()
            local budget = currentBudget(players)
            local active = populationCounts()
            if active < budget then
                -- The cadence wait also starts a fresh scan allowance.
                scanWork = 0
                spawnOne(players)
            end
        end
        Wait(CONFIG.spawnEveryMs)
    end
end)

-- Snapshot identities, not verdicts. Each small chunk re-reads the canonical
-- state; no retirement decision survives a yield, reset or settings generation.
local MONITOR_WORK_PER_RESUME = 8
local function monitorFleet(now)
    local passGeneration = generation
    local ids = {}
    for id, entry in pairs(cars) do ids[#ids + 1] = { id = id, entry = entry } end
    local positions = observationPositions()
    for index, item in ipairs(ids) do
        if index > 1 and (index - 1) % MONITOR_WORK_PER_RESUME == 0 then
            Wait(0)
            positions = observationPositions()
        end
        if stopping or resetting or passGeneration ~= generation then return end
        now = Open77.time.monotonic()
        local vehicleId, entry = item.id, cars[item.id]
        if entry == item.entry then
        local vehicle = Open77.vehicles.get(vehicleId)
        local reason, unownable, trailing
        -- Any live car frees its spawn spot once it has left it, whatever its
        -- task says: a held stalled car can roll away from its spot too.
        if vehicle and entry.runtime.use[entry.corridorIndex] == vehicleId then
            local position = vehicle.position or entry.lastPosition
            local dx, dy = position.x - entry.spawnPosition.x, position.y - entry.spawnPosition.y
            if dx * dx + dy * dy > SPOT_RELEASE_METRES * SPOT_RELEASE_METRES then
                releaseCorridor(entry, vehicleId)
            end
        end
        if not vehicle then
            releaseDriver(vehicleId, entry)
            releaseTracking(vehicleId, entry)
        elseif driverKilled(entry) then
            -- Before the task is read at all: whatever it says for the next
            -- tick or so, the car's disposition is its driver's death.
            reason = "driver_dead"
        elseif vehicleWrecked(vehicle) then
            entry.wreckedSince = entry.wreckedSince or now
            if now - entry.wreckedSince >= WRECK_DEATH_GRACE_SECONDS then reason = "wrecked" end
        else
            local state = Open77.vehicles.ai.state(vehicleId)
            if not state then
                reason = "task_missing"
            elseif state.status == "arrived" then
                reason = "unexpected_arrival"
                log("invariant breach: ambient car %s entered arrived state", tostring(vehicleId))
            elseif state.status == "failed" or state.status == "cancelled" then
                reason = state.reason or state.status
                -- A failed retry remains stalled until it executes, exhausts
                -- its retry limit, or cannot acquire a simulator.
                -- A player aboard takes the ordinary `released` path in `retire`.
                if state.status == "failed" and (state.reason == "impact_recovery_failed"
                    or interruptedJoin(entry, state, now) and observedWithin(vehicle, STREAM_OUT_METRES, positions)
                    or entry.stalledSince)
                    and not playerOccupied(vehicle) then
                    if not entry.stalledSince then
                        if state.reason == "impact_recovery_failed" then noteImpactFailure(entry, now) end
                        -- A car that ran before failing proves its corridor can
                        -- join; the held car may never reach `retire` to say so.
                        noteJoinOutcome(entry, state.reason)
                    end
                    entry.stalledSince = entry.stalledSince or now
                    if observedWithin(vehicle, STREAM_OUT_METRES, positions) then
                        if state.reason ~= "simulator_recovery_failed"
                            and (entry.stalledRetries or 0) < STALLED_RETRY_LIMIT then
                            if not entry.stalledReported then
                                entry.stalledReported = true
                                log("holding stalled car %s in view reason=%s profile=%s",
                                    tostring(vehicleId), reason, entry.profileName)
                            end
                            entry.stalledUnobservedSince = nil
                            entry.stalledRetryAt = entry.stalledRetryAt or now + STALLED_RETRY_SECONDS
                            if now >= entry.stalledRetryAt then
                                entry.stalledRetryAt = nil
                                entry.stalledRetries = (entry.stalledRetries or 0) + 1
                                -- The failed task released its simulator and the hold
                                -- tracks no epochs: the retried task starts the churn
                                -- baseline afresh.
                                entry.lastEpoch = 0
                                local joined, refusal = Open77.vehicles.ai.joinTraffic(vehicleId, {
                                    timeoutMilliseconds = CONFIG.timeoutMilliseconds,
                                })
                                log("retrying stalled car %s attempt=%d ok=%s reason=%s", tostring(vehicleId),
                                    entry.stalledRetries, tostring(joined ~= nil), joined and reason or tostring(refusal))
                            end
                            reason = nil
                        end
                    else
                        entry.stalledUnobservedSince = entry.stalledUnobservedSince or now
                        if now - entry.stalledUnobservedSince < STALLED_UNOBSERVED_SECONDS then reason = nil end
                    end
                end
            else
                if entry.stalledSince and state.status == "running" and state.execution == "executing" then
                    log("stalled car %s rejoined traffic attempt=%d after %d s", tostring(vehicleId),
                        entry.stalledRetries or 0, math.floor(now - entry.stalledSince))
                    entry.stalledSince, entry.stalledReported, entry.stalledUnobservedSince = nil, nil, nil
                    entry.stalledRetryAt, entry.stalledRetries = nil, nil
                end
                local epoch = tonumber(state.epoch) or 0
                if entry.lastEpoch > 0 and epoch > entry.lastEpoch + 2 then reason = "authority_churn" end
                entry.lastEpoch = epoch

                local owner = tonumber(state.owner) or 0
                if owner > 0 then
                    entry.hadOwner = true
                    entry.orphanSince, entry.neverOwnedSince = nil, nil
                    entry.orphanSeconds = 0
                    entry.neverOwnedSeconds = 0
                    entry.retirementNoted, entry.retireUnobservedSince = nil, nil
                elseif entry.hadOwner then
                    entry.orphanSince = entry.orphanSince or now
                    entry.orphanSeconds = now - entry.orphanSince
                else
                    entry.neverOwnedSince = entry.neverOwnedSince or entry.spawnedAt or now
                    entry.neverOwnedSeconds = now - entry.neverOwnedSince
                end

                -- The car's position is what spawn separation and the
                -- ground/clearance checks read. Motion is NOT a retirement
                -- input: the engine's traffic enrollment legitimately
                -- holds a car still (a red light, a queue) for longer than
                -- any fixed no-motion window, so zero movement alone must
                -- never destroy or re-issue it.
                local position = vehicle.position or entry.lastPosition
                entry.lastPosition = { x = position.x, y = position.y, z = position.z }
                -- Timeouts request cleanup; retire still requires the car and
                -- driver to be unobserved. Monitor yields do not advance time.
                if not entry.stalledSince and not playerOccupied(vehicle) then
                    if entry.orphanSeconds >= CONFIG.orphanSeconds then reason = "owner_lost" end
                    if entry.neverOwnedSeconds >= CONFIG.neverOwnedSeconds then reason = "never_owned" end
                    -- The server's own election answer, not a radius copied here:
                    -- `simulator_out_of_range` means no viewer is near enough to be
                    -- elected (the 350-425 m gap); a viewer nearby that is not ready
                    -- yet, suppressed or full keeps the in-view protection.
                    unownable = (reason == "owner_lost" or reason == "never_owned")
                        and state.status == "waiting_for_simulator" and state.reason == "simulator_out_of_range"
                end
                -- After the timeouts, before the distance rule: a trailing car
                -- is released whatever its streaming state (see `trailingCar`).
                if not reason and not entry.stalledSince
                    and not playerOccupied(vehicle) and positions
                    and trailingCar(position, vehicle.bucket or 0, positions) then
                    entry.trailingSince = entry.trailingSince or now
                    if now - entry.trailingSince >= NATIVE_TRAIL_SECONDS then
                        reason, trailing = "trailing", true
                    end
                else
                    entry.trailingSince = nil
                end
                -- The configured cleanup distance cannot override an existing
                -- projection. Require continuous absence from all viewers;
                -- density/admission limits bound generation while far cars are
                -- still visible, rather than freeing slots by erasing them.
                local retireDistance = math.min(STREAM_OUT_METRES,
                    math.max(CONFIG.retireDistance, CONFIG.groundProbeRadius + 50))
                if observedWithin({ x = position.x, y = position.y, z = position.z,
                    bucket = vehicle.bucket }, retireDistance, positions)
                    or vehicleObserved(vehicleId, vehicle, positions) then
                    entry.unobservedSince = nil
                else
                    entry.unobservedSince = entry.unobservedSince or now
                    if not reason and now - entry.unobservedSince >= UNOBSERVED_GRACE_SECONDS then
                        reason = "out_of_range"
                    end
                end
            end
        end
        if reason then retire(vehicleId, reason, unownable, trailing) end
        end
    end
end

-- Whether any player of the body's bucket is inside its streaming window: the
-- boundary within which a client can have the body streamed at all.
local function corpseObserved(npc, positions)
    return observedWithin(npc, (finite(npc.streamingRadius) and npc.streamingRadius or 180)
        + (finite(npc.streamingHysteresis) and npc.streamingHysteresis or 40), positions)
end

-- Whether a kept body still sits in its car's driver seat: the driving service
-- keeps a killed driver's job attached, naming it, until the seat is stolen or
-- the job is detached for any other cause.
local function corpseSeated(driverId, corpse)
    local state = Open77.vehicles.ai.state(corpse.vehicleId)
    return type(state) == "table" and state.status ~= "detached"
        and math.tointeger(tonumber(state.npcId)) == driverId
end

-- The same identity/generation fence as the fleet scan protects corpse cleanup
-- across yields: a reset can clear or replace either ledger in the gap.
local function sweepCorpses(now)
    if next(corpses) == nil then return end
    local passGeneration = generation
    local ids = {}
    for id, corpse in pairs(corpses) do ids[#ids + 1] = { id = id, corpse = corpse } end
    local positions = observationPositions()
    for index, item in ipairs(ids) do
        if index > 1 and (index - 1) % MONITOR_WORK_PER_RESUME == 0 then
            Wait(0)
            positions = observationPositions()
        end
        if stopping or resetting or passGeneration ~= generation then return end
        now = Open77.time.monotonic()
        local driverId, corpse = item.id, corpses[item.id]
        if corpse == item.corpse then
        local npc = Open77.npcs.get(driverId)
        local reason
        if type(npc) ~= "table" then
            reason = "gone"
        elseif not Open77.vehicles.get(corpse.vehicleId) then
            reason = "car_removed"
        elseif corpseSeated(driverId, corpse) then
            -- A seated body goes with its car; its clocks start at the drag-out.
            corpse.releasedAt, corpse.unobservedSince = now, nil
        elseif now - corpse.releasedAt >= CORPSE_MAXIMUM_SECONDS then
            reason = "maximum_age"
        elseif corpseObserved(npc, positions) then
            corpse.unobservedSince = nil
        else
            corpse.unobservedSince = corpse.unobservedSince or now
            if now - corpse.unobservedSince >= CORPSE_UNOBSERVED_SECONDS then reason = "unobserved" end
        end
        if reason then
            corpses[driverId] = nil
            if type(npc) == "table" then Open77.npcs.remove(driverId) end
            log("removed driver corpse %s of car %s reason=%s cause=%s source=%s",
                tostring(driverId), tostring(corpse.vehicleId), reason, corpse.cause, corpse.source)
        end
        end
    end
end

-- Traffic is server-priced, like deathmatch's player -> bot path. The private
-- client envelope contains counted contact observations, never a health price,
-- lethal flag or headshot multiplier. Native/public fractions are not inputs.
-- Metadata is the shipped server catalogue; equipment/contacts remain client
-- evidence, not an authoritative handheld shot/ammunition/LOS ledger.
local DRIVER_DAMAGE_CAUSES = { [1] = "firearm", [2] = "melee", [3] = "explosion" }
local DRIVER_DAMAGE_REACH = { [1] = 506, [2] = 14, [3] = 56 } -- PvP reach + 6 m tolerance
local DRIVER_DAMAGE_REPORTS_PER_SECOND = 20
local DRIVER_DAMAGE_BATCH_LIMIT = 16
local DRIVER_WEAPON_PRICE = {
    Wea_Handgun = 26, Wea_SubmachineGun = 18, Wea_Rifle = 22,
    Wea_Shotgun = 58, Wea_ShotgunDual = 62, Wea_SniperRifle = 90,
    Wea_PrecisionRifle = 65, Wea_Revolver = 45,
    Wea_LightMachineGun = 16, Wea_HeavyMachineGun = 16,
}
local DRIVER_MELEE_PRICE = {
    Wea_Fists = 25, Wea_Knife = 35, Wea_Axe = 35,
    Wea_OneHandedClub = 45, Cyb_StrongArms = 45,
    Wea_Katana = 55, Wea_LongBlade = 55, Wea_Machete = 55,
    Wea_Sword = 55, Wea_Chainsword = 55, Cyb_MantisBlades = 55, Cyb_NanoWires = 55,
    Wea_Hammer = 65, Wea_TwoHandedClub = 65, Wea_Melee = 25,
}

local function driverHitPrice(weapon, kind)
    if weapon == 0 then
        if kind == 2 then return 25 * CONFIG.driverDamageScale, "Wea_Fists" end
        if kind == 3 then return 70 * CONFIG.driverDamageScale, "weaponless_blast" end
        return nil, "weapon"
    end
    local record = Open77.data.weapon(("0x%X"):format(weapon))
    if type(record) ~= "table" or type(record.itemType) ~= "string" then return nil, "weapon_unknown" end
    local class = record.itemType:match("^ItemType%.(.+)$")
    local firearm, melee = DRIVER_WEAPON_PRICE[class], DRIVER_MELEE_PRICE[class]
    local explosive = class == "Gad_Grenade" or class == "Wea_GrenadeLauncher" or class == "Cyb_Launcher"
    local price
    if kind == 1 then
        price = firearm or (explosive and 70) or ((class == "Wea_Knife" or class == "Wea_Axe") and melee)
    elseif kind == 2 then
        price = melee or (firearm and 25) -- a real weapon bash, not a firearm-price melee hit
    elseif kind == 3 and (explosive or firearm) then
        price = 70 -- includes an explosive round, never native splash magnitude
    end
    if not price then return nil, "weapon_kind" end
    return price * CONFIG.driverDamageScale, class
end
local driverDamageWindows = {}
-- Unlike the short admission window, replay watermarks live until disconnect.
local driverDamageClaims = {}
local driverDamageRefusals = {}

local function refuseDriverDamage(reason, count)
    driverDamageRefusals[reason] = (driverDamageRefusals[reason] or 0) + (count or 1)
end

local function driverDamageAdmitted(playerId, now)
    local window = driverDamageWindows[playerId]
    if not window then
        window = { at = now, tokens = DRIVER_DAMAGE_REPORTS_PER_SECOND,
            hits = CONFIG.driverHitsPerSecond, melee = 10, damage = CONFIG.driverDamagePerSecond }
        driverDamageWindows[playerId] = window
    end
    local elapsed = math.max(0, now - window.at)
    window.tokens = math.min(DRIVER_DAMAGE_REPORTS_PER_SECOND, window.tokens + elapsed * DRIVER_DAMAGE_REPORTS_PER_SECOND)
    window.hits = math.min(CONFIG.driverHitsPerSecond, window.hits + elapsed * CONFIG.driverHitsPerSecond)
    window.melee = math.min(10, window.melee + elapsed * 10)
    window.damage = math.min(CONFIG.driverDamagePerSecond, window.damage + elapsed * CONFIG.driverDamagePerSecond)
    window.at = now
    if window.tokens < 1 then return false end
    window.tokens = window.tokens - 1
    return window
end

local function driverWeaponMatches(playerId, weapon, kind, age, class)
    -- Unarmed melee and weaponless grenade/blast receipts are native paths;
    -- ranged damage, unlike those paths, must name a weapon.
    if weapon == 0 then return kind ~= 1 end
    if kind == 2 and class == "Wea_Fists" then return true end
    local evidence = Open77.weapons.get(playerId)
    -- This is a CLIENT-REPORTED equipment cache, not proof of a shot or price.
    -- A current active-only snapshot cannot disprove a switched/delayed hit.
    if type(evidence) ~= "table" or not evidence.fresh or evidence.source ~= "report" then return true end
    if tonumber(evidence.activeTweakDbId) == weapon then return true end
    for _, slot in ipairs(evidence.slots or {}) do
        if tonumber(slot.tweakDbId) == weapon then return true end
    end
    -- A grenade may have left the gadget slot before its delayed explosion.
    -- Only immediate ranged/melee reports can be contradicted by this cache.
    if kind == 3 then return true end
    -- A loadout changed after the hit cannot contradict the old equipment.
    if not finite(evidence.loadoutAgeMs) or evidence.loadoutAgeMs <= age * 1000 + 250 then return true end
    return false
end

local function applyDriverObservation(playerId, shooter, window, observation)
    if type(observation) ~= "table" then return refuseDriverDamage("claim") end
    local count = math.tointeger(tonumber(observation.count))
    if not count or count < 1 or count > DRIVER_DAMAGE_BATCH_LIMIT then return refuseDriverDamage("count") end
    local age = tonumber(observation.age)
    if not finite(age) or age < 0 or age > 30 then return refuseDriverDamage("stale", count) end
    local kind = math.tointeger(tonumber(observation.kind))
    local cause = DRIVER_DAMAGE_CAUSES[kind]
    local weapon = math.tointeger(tonumber(observation.weapon))
    if not cause or not weapon or weapon < 0 then return refuseDriverDamage("claim", count) end
    local npcId = observation.npc
    local driverId = math.tointeger(tonumber(npcId))
    local vehicleId = driverId and driverCars[driverId]
    local entry = vehicleId and cars[vehicleId]
    if not entry or entry.driverId ~= driverId then return refuseDriverDamage("driver", count) end
    local npc = Open77.npcs.get(driverId)
    if type(npc) ~= "table" or npc.resource ~= GetCurrentResourceName()
        or npc.damagePolicy ~= Open77.npcs.damage.mortal or not finite(npc.health) or npc.health <= 0
        or not finite(npc.maxHealth) or npc.maxHealth <= 0
        or not finite(npc.x) or not finite(npc.y) or not finite(npc.z) then return refuseDriverDamage("driver", count) end
    -- The packet's shooter comes only from the fresh authority roster.
    if type(shooter) ~= "table" or (shooter.bucket or 0) ~= (npc.bucket or 0)
        or not finite(shooter.x) or not finite(shooter.y) or not finite(shooter.z) then return refuseDriverDamage("pose", count) end
    if Open77.vehicles.isVisibleTo(vehicleId, playerId) ~= true then return refuseDriverDamage("visibility", count) end
    local reach = math.min(DRIVER_DAMAGE_REACH[kind],
        (finite(npc.streamingRadius) and npc.streamingRadius or 180)
        + (finite(npc.streamingHysteresis) and npc.streamingHysteresis or 40))
    local dx, dy, dz = shooter.x - npc.x, shooter.y - npc.y, shooter.z - npc.z
    if dx * dx + dy * dy + dz * dz > reach * reach then return refuseDriverDamage("reach", count) end
    local price, class = driverHitPrice(weapon, kind)
    if not price then return refuseDriverDamage(class, count) end
    if not driverWeaponMatches(playerId, weapon, kind, age, class) then return refuseDriverDamage("weapon", count) end
    -- Weighted, player-wide admission: folding/count/extra targets cannot buy
    -- additional hits or damage. Admit only affordable whole observations and
    -- account for every rejected remainder (never silently truncate a count).
    local admitted = math.min(count, math.max(0, math.floor(window.hits + 1e-9)))
    if admitted < count then refuseDriverDamage("cadence", count - admitted) end
    count = admitted
    if kind == 2 then
        admitted = math.min(count, math.max(0, math.floor(window.melee + 1e-9)))
        if admitted < count then refuseDriverDamage("melee_cadence", count - admitted) end
        count = admitted
    end
    admitted = math.min(count, math.max(0, math.floor((window.damage + 1e-9) / price)))
    if admitted < count then refuseDriverDamage("dps", count - admitted) end
    count = admitted
    if count == 0 then return end
    local priced = price * count
    window.hits = window.hits - count
    if kind == 2 then window.melee = window.melee - count end
    window.damage = window.damage - priced
    local amount = math.min(npc.health, priced)
    -- Canonical HP and applied amounts are float32. Repeated fractional SERVER
    -- prices can leave rounding dust after an otherwise lethal total. Snap only
    -- that negligible remainder; native fractions/kill flags are never inputs,
    -- and even an unusually large health pool cannot erase a real 0.01 HP wound.
    local residue = npc.health - amount
    if residue > 0 and residue <= math.min(0.001, npc.maxHealth * 1e-5) then amount = npc.health end
    local called, applied = pcall(Open77.npcs.applyDamage, driverId, amount, "player:" .. playerId, cause)
    if not called or applied ~= true then refuseDriverDamage(called and "apply" or "apply_error", count) end
end

RegisterNetEvent("open77_traffic:driverDamage", function(observations, claimId)
    if not CONFIG.driversKillable then return refuseDriverDamage("disabled") end
    local playerId = math.tointeger(tonumber(source))
    if not playerId or playerId <= 0 or not playerLive(playerId) then return refuseDriverDamage("source") end
    local window = driverDamageAdmitted(playerId, Open77.time.monotonic())
    if not window then return refuseDriverDamage("rate") end
    local sequence = math.tointeger(tonumber(claimId))
    if not sequence or sequence <= 0 or sequence > 9007199254740991
        or sequence <= (driverDamageClaims[playerId] or 0) then return refuseDriverDamage("replay") end
    driverDamageClaims[playerId] = sequence
    if type(observations) ~= "table" or #observations < 1 or #observations > DRIVER_DAMAGE_BATCH_LIMIT then
        return refuseDriverDamage("batch")
    end
    local total = 0
    for index = 1, #observations do
        local row = observations[index]
        local count = type(row) == "table" and math.tointeger(tonumber(row.count)) or nil
        if not count or count < 1 or count > DRIVER_DAMAGE_BATCH_LIMIT then return refuseDriverDamage("count") end
        total = total + count
    end
    if total > DRIVER_DAMAGE_BATCH_LIMIT then return refuseDriverDamage("batch", total) end
    local positions = Open77.players.positions()
    local shooter = type(positions) == "table" and positions[playerId] or nil
    for index = 1, #observations do applyDriverObservation(playerId, shooter, window, observations[index]) end
end)

AddEventHandler("onPlayerDisconnected", function(id)
    driverDamageWindows[tonumber(id) or id] = nil
    driverDamageClaims[tonumber(id) or id] = nil
end)

-- One summary line per window instead of one line per refused attempt.
local function reportDeferrals(now)
    if now - deferralsReportedAt < DEFERRAL_REPORT_SECONDS then return end
    deferralsReportedAt = now
    -- Reuse the summary cadence even when there is nothing to log.
    for id, window in pairs(driverDamageWindows) do
        if now - window.at >= 1 then driverDamageWindows[id] = nil end
    end
    local refused = {}
    for reason, count in pairs(driverDamageRefusals) do
        refused[#refused + 1] = reason .. "=" .. count
        driverDamageRefusals[reason] = nil
    end
    if #refused > 0 then
        table.sort(refused)
        log("driver damage refusals in the last %d s: %s", DEFERRAL_REPORT_SECONDS, table.concat(refused, " "))
    end
    local positions = observationPositions()
    if positions then
        local buckets = {}
        for _, position in pairs(positions) do buckets[position.bucket] = true end
        for bucket, runtime in pairs(corridorRuntimeByBucket) do
            if not buckets[bucket] and next(runtime.use) == nil
                and now - runtime.lastUsedAt >= CORRIDOR_QUARANTINE_SECONDS then
                corridorRuntimeByBucket[bucket] = nil
            end
        end
    end
    local any = false
    for _, count in pairs(deferrals) do
        if count ~= 0 then any = true break end
    end
    if not any then return end
    log("spawn deferrals in the last %d s: precheck=%d clearance=%d fleet_moved=%d ground_miss=%d",
        DEFERRAL_REPORT_SECONDS, deferrals.precheck, deferrals.clearance, deferrals.fleetMoved,
        deferrals.groundMiss)
    resetDeferrals()
end

CreateThread(function()
    while not stopping do
        Wait(1000)
        -- A reset owns the fleet for its duration: a retirement verdict read
        -- from a ledger the reset is walking would act on a car that is already
        -- being deleted, and a car condemned mid-reset would be gone anyway.
        if not resetting then
            local now = Open77.time.monotonic()
            monitorFleet(now)
            sweepCorpses(now)
        end
        reportDeferrals(Open77.time.monotonic())
    end
end)

-- ---------------------------------------------------------------------------
-- The operator panel
-- ---------------------------------------------------------------------------
--
-- One restricted command is the panel's whole server surface. Every control the
-- page offers comes back through `open77:command:execute` and lands here, and
-- the `command.traffic` grant is the authorization boundary: no request names a
-- player, and the player a snapshot describes is always the authenticated
-- source of the command itself. Nothing here writes a setting directly --
-- `set` goes through `Open77.tunables.set`, so the panel, the Warden form and
-- the console all pass the same validation and all persist.
--
-- What the server sends back:
--   open77_traffic:panel:open    the first snapshot, on `traffic open`
--   open77_traffic:panel:data    a snapshot, on `traffic state <radius>`
--   open77_traffic:panel:result  what one mutation did, and nothing else
--
-- A pattern request is reported as a REQUEST: the snapshot's patternStatus is
-- the only place a native outcome ever appears, because the pattern is applied
-- by the client that owns the car after this command has answered.
local PANEL_OPEN = "open77_traffic:panel:open"
local PANEL_DATA = "open77_traffic:panel:data"
local PANEL_RESULT = "open77_traffic:panel:result"

local PANEL_DEFAULT_RADIUS = 100
local PANEL_MIN_RADIUS = 1
local PANEL_MAX_RADIUS = 500
local PANEL_ROW_LIMIT = 12

local function panelSend(event, source, payload)
    local sent, reason = TriggerClientEvent(event, source, payload)
    if sent == false then
        log("panel push %s to %d failed: %s", event, source, tostring(reason))
    end
    return sent
end

local function panelResult(source, result)
    if result.ok ~= true then log("refused %s: %s", tostring(result.operation), tostring(result.message)) end
    return panelSend(PANEL_RESULT, source, result)
end

-- The panel is a player's instrument: the radius is measured from their own
-- authenticated position and in their own routing bucket, so a command without
-- a ready, living player behind it has nothing to describe.
local function panelAnchor(source)
    local playerId = tonumber(source)
    if not playerId or playerId <= 0 then return nil end
    return currentPlayerAnchor(playerId)
end

local function panelRadius(raw)
    if raw == nil then return PANEL_DEFAULT_RADIUS end
    local value = tonumber(raw)
    if not value or not finite(value) or value % 1 ~= 0
        or value < PANEL_MIN_RADIUS or value > PANEL_MAX_RADIUS then
        return nil, ("radius must be a whole number of metres between %d and %d")
            :format(PANEL_MIN_RADIUS, PANEL_MAX_RADIUS)
    end
    return value
end

-- Centre-to-centre distance from the requesting player to a tracked car, or nil
-- when the car is in another routing bucket or outside the radius. One
-- definition for a snapshot row and for a pattern sweep both, so the numbers
-- the panel shows and the button that acts on them always describe the same
-- cars.
local function trackedDistance(entry, position, anchor, radiusSquared)
    if entry.bucket ~= anchor.bucket then return nil end
    if type(position) ~= "table"
        or not (finite(position.x) and finite(position.y) and finite(position.z)) then
        return nil
    end
    local dx = position.x - anchor.position.x
    local dy = position.y - anchor.position.y
    local dz = position.z - anchor.position.z
    local squared = dx * dx + dy * dy + dz * dz
    if squared > radiusSquared then return nil end
    return math.sqrt(squared)
end

-- The value in force for every setting, read from CONFIG, which is the same
-- table the spawn loop reads, so a control can never show a number the
-- controller is not using. The declarations themselves live in
-- shared/config.lua, which the client half loads too, so they are not re-sent:
-- repeating them on every poll pushed the snapshot past the host's 1,024-value
-- event limit and the page refused it.
local function settingValues()
    local values = {}
    for key in pairs(TrafficSettings) do values[key] = CONFIG[key] end
    return values
end

local function panelSnapshot(anchor, radius)
    local radiusSquared = radius * radius
    local active, totalOwned, drivers = 0, 0, 0
    local matched, applied, pending, failed = 0, 0, 0, 0
    -- Panic outcomes of the matched cars: `active` is a confirmed native
    -- reaction, `pending` one still waiting for its simulator, and `notApplied`
    -- the requests that ended blocked or refused.
    local panic = { active = 0, pending = 0, notApplied = 0 }
    local phases = { enrolling = 0, moving = 0, healthy_waiting = 0, recovering = 0, failed_retiring = 0 }
    local rows = {}
    local ids = {}
    for vehicleId in pairs(cars) do ids[#ids + 1] = vehicleId end
    local work = 0
    for index = 1, #ids do
        local vehicleId = ids[index]
        local entry = cars[vehicleId]
        if entry then
            totalOwned = totalOwned + 1
            if entry.driverId then drivers = drivers + 1 end
            -- One canonical read per car: it says whether the car still exists
            -- (the monitor clears a ledger entry whose car has gone) and it
            -- carries the pose the distance is measured on.
            local vehicle = Open77.vehicles.get(vehicleId)
            if vehicle then
                active = active + 1
                local state = Open77.vehicles.ai.state(vehicleId)
                local phase = state and state.phase or "failed_retiring"
                phases[phase] = (phases[phase] or 0) + 1
                local position = vehicle.position or entry.lastPosition
                local distance = trackedDistance(entry, position, anchor, radiusSquared)
                if distance then
                    matched = matched + 1
                    local status = "inactive"
                    local pattern = "default"
                    local patternReason = ""
                    local owner = ""
                    local panicStatus, panicReason = "inactive", ""
                    if state then
                        status = state.patternStatus or "inactive"
                        pattern = state.pattern or "default"
                        patternReason = tostring(state.patternReason or "")
                        owner = tostring(state.owner or "")
                        panicStatus = state.panicStatus or "inactive"
                        panicReason = tostring(state.panicReason or "")
                    end
                    if status == "applied" then applied = applied + 1
                    elseif status == "pending" then pending = pending + 1
                    elseif status == "failed" then failed = failed + 1 end
                    if panicStatus == "active" then panic.active = panic.active + 1
                    elseif panicStatus == "pending" then panic.pending = panic.pending + 1
                    elseif panicStatus == "blocked" or panicStatus == "refused" then
                        panic.notApplied = panic.notApplied + 1
                    end
                    rows[#rows + 1] = {
                        id = tostring(vehicleId),
                        record = vehicle.record or "",
                        owner = owner,
                        phase = phase,
                        reason = state and state.reason or "",
                        pattern = pattern,
                        patternStatus = status,
                        patternReason = patternReason,
                        panicStatus = panicStatus,
                        panicReason = panicReason,
                        -- The canonical registry's own reading: the speed the
                        -- simulator last reported for this car, in metres per
                        -- second. The driving task's `speed` is the configured
                        -- legacy value a traffic enrollment does not honour, so
                        -- reading it here would report a constant for every car
                        -- instead of a measurement.
                        speed = finite(vehicle.speed) and vehicle.speed or 0,
                        distance = distance,
                    }
                end
            end
        end
        work = work + 1
        if work >= COMMAND_WORK_PER_RESUME and index < #ids then
            work = 0
            Wait(0)
        end
    end
    -- Nearest first, so the cap shows the cars the operator is standing among.
    -- The counts above are every match, not the rows that fit.
    table.sort(rows, function(left, right)
        if left.distance ~= right.distance then return left.distance < right.distance end
        return left.id < right.id
    end)
    local shown = {}
    for index = 1, math.min(#rows, PANEL_ROW_LIMIT) do shown[index] = rows[index] end
    local capacity = Open77.vehicles.ai.capacity()
    return {
        settings = settingValues(),
        -- The one declaration this file rewrites at start-up (from the convar),
        -- so the client's own copy of config.lua cannot know its default.
        defaults = { enabled = TrafficSettings.enabled.value },
        stats = {
            active = active,
            totalOwned = totalOwned,
            drivers = drivers,
            desired = CONFIG.carsGlobal,
            admittedBudget = currentBudget(activePlayers(), capacity),
            -- Only what the page shows; the per-owner breakdown is not.
            capacity = capacity and {
                globalUsed = capacity.globalUsed,
                perSimulatorLimit = capacity.perSimulatorLimit,
            } or nil,
            phases = phases,
            enabled = CONFIG.enabled == true,
            resetting = resetting,
            generation = generation,
        },
        nearby = {
            radius = radius,
            bucket = anchor.bucket,
            total = matched,
            shown = #shown,
            applied = applied,
            pending = pending,
            failed = failed,
            panic = panic,
            vehicles = shown,
        },
    }
end

-- A reason from the driving service travels into a panel row and into a result
-- message, so it is bounded to the shape the service's own tokens have: the
-- first run of word characters, at most 48 of them.
local function boundedReason(reason)
    local text = tostring(reason or "")
    return (text:match("^[%w_]+") or ""):sub(1, 48)
end

-- The tracked cars of the anchor's bucket within `radius`, in id order: the
-- one selection both panel sweeps act on, so the numbers the snapshot shows and
-- the cars a button reaches are always the same cars.
local function carsInRange(anchor, radius)
    local radiusSquared = radius * radius
    local ids = {}
    for vehicleId, entry in pairs(cars) do
        local vehicle = Open77.vehicles.get(vehicleId)
        if vehicle then
            local position = vehicle.position or entry.lastPosition
            if trackedDistance(entry, position, anchor, radiusSquared) then
                ids[#ids + 1] = vehicleId
            end
        end
    end
    table.sort(ids)
    return ids
end

-- One call per selected car that is still tracked, bounded per resume. A
-- refusal names itself: every call here answers nil + reason for each
-- documented case rather than raising.
local function sweep(ids, request)
    local requested, refused, firstReason, firstState = 0, 0, nil, nil
    local work = 0
    for index = 1, #ids do
        if cars[ids[index]] then
            local state, reason = request(ids[index])
            if state then
                requested = requested + 1
                firstState = firstState or state
            else
                refused = refused + 1
                firstReason = firstReason or boundedReason(reason)
            end
        end
        work = work + 1
        if work >= COMMAND_WORK_PER_RESUME and index < #ids then
            work = 0
            Wait(0)
        end
    end
    return requested, refused, firstReason, firstState
end

-- Explicitly requested native patterns are one of the two things this resource
-- ever asks a driving task to change: the join task itself is never replaced,
-- renewed or cancelled here, so a pattern never costs a car its driving intent.
-- An accepted Stop or Default also ends a panic still pending or running on
-- that car.
--
-- The result describes the REQUEST -- which cars took it and which refused it
-- on the spot. The native outcome is not knowable yet: it is applied by the
-- client that owns the car, and it is the snapshot's patternStatus
-- (pending/applied/failed) that reports it later.
local function applyPattern(anchor, pattern, radius)
    local ids = carsInRange(anchor, radius)
    if #ids == 0 then
        return {
            ok = false, operation = "pattern", matched = 0, requested = 0, failed = 0,
            message = ("no tracked car in this bucket within %d m"):format(radius),
        }
    end
    local requested, refused, firstReason = sweep(ids, function(vehicleId)
        return Open77.vehicles.ai.setTrafficPattern(vehicleId, pattern)
    end)
    local parts = {
        ("requested %s on %d of %d car(s) within %d m"):format(pattern, requested, #ids, radius),
    }
    if refused > 0 then
        parts[#parts + 1] = ("%d refused it on the spot (%s)")
            :format(refused, firstReason or "unknown_reason")
    end
    parts[#parts + 1] = "native status follows on the next snapshot"
    return {
        ok = requested > 0, operation = "pattern", matched = #ids,
        requested = requested, failed = refused,
        message = table.concat(parts, "; "),
    }
end

-- What one car's panic request looks like to a caller: the request token that
-- correlates it, where it stands, why a terminal one ended, and its duration.
local function panicView(vehicleId, state)
    return {
        vehicleId = tostring(vehicleId),
        request = state.panicRequest,
        status = state.panicStatus,
        reason = state.panicReason,
        durationMs = state.panicDurationMs,
        remainingMs = state.panicRemainingMs,
    }
end

local function trackedVehicle(vehicleId)
    local number = tonumber(vehicleId)
    local id = number and math.tointeger(number)
    if id == nil or cars[id] == nil then return nil end
    return id
end

-- The one supported per-vehicle panic path. The panel's Panic button and the
-- `panic` export both land here: a car this resource tracks, the caller's
-- threat, and the driving service's own bounded request. Only the options the
-- service documents are forwarded, so a caller can neither reach another
-- resource's car through this one nor pass anything else to the task.
--
-- The answer is the REQUEST: `pending` with a fresh token. The native outcome
-- -- active, then ended; or blocked / refused / cancelled -- is correlated to
-- that token and read back through `panicState` or a later snapshot. A
-- repeated threat is a new request that replaces the previous one.
local function requestPanic(vehicleId, options)
    local id = trackedVehicle(vehicleId)
    if id == nil then return nil, "not_traffic_vehicle" end
    if type(options) ~= "table" then return nil, "invalid_options" end
    local state, reason = Open77.vehicles.ai.panic(id, {
        threatPosition = options.threatPosition,
        threatKind = options.threatKind,
        threatId = options.threatId,
        durationMilliseconds = options.durationMilliseconds,
    })
    if not state then return nil, boundedReason(reason) end
    return panicView(id, state)
end

local function panicState(vehicleId)
    local id = trackedVehicle(vehicleId)
    if id == nil then return nil, "not_traffic_vehicle" end
    local state = Open77.vehicles.ai.state(id)
    if not state then return nil, "task_missing" end
    return panicView(id, state)
end

-- The panel's Panic: the same per-vehicle request for every car in range, with
-- the operator as the threat.
local function applyPanic(anchor, radius, playerId)
    local ids = carsInRange(anchor, radius)
    if #ids == 0 then
        return {
            ok = false, operation = "panic", matched = 0, requested = 0, failed = 0,
            message = ("no tracked car in this bucket within %d m"):format(radius),
        }
    end
    local threat = {
        threatPosition = { x = anchor.position.x, y = anchor.position.y, z = anchor.position.z },
        threatKind = "player", threatId = playerId,
    }
    local requested, refused, firstReason, firstState = sweep(ids, function(vehicleId)
        return requestPanic(vehicleId, threat)
    end)
    local durationSeconds = firstState and tonumber(firstState.durationMs)
    durationSeconds = durationSeconds and durationSeconds / 1000 or nil
    local parts = {
        ("requested panic on %d of %d car(s) within %d m"):format(requested, #ids, radius),
    }
    if refused > 0 then
        parts[#parts + 1] = ("%d refused it on the spot (%s)")
            :format(refused, firstReason or "unknown_reason")
    end
    if durationSeconds then
        parts[#parts + 1] = ("each runs %g s from when its simulator confirms it, then rejoins traffic")
            :format(durationSeconds)
    end
    parts[#parts + 1] = "native status follows on the next snapshot"
    return {
        ok = requested > 0, operation = "panic", matched = #ids,
        requested = requested, failed = refused, durationSeconds = durationSeconds,
        message = table.concat(parts, "; "),
    }
end

-- Server resources the operator approved as panic callers: the
-- `panicResources` setting, split on anything that cannot be part of a
-- resource name. `none` and an empty value approve nobody.
local function panicCallerApproved(caller)
    if type(caller) ~= "string" or caller == "" or caller == "none" then return false end
    for name in tostring(CONFIG.panicResources or ""):gmatch("[%w_%-]+") do
        if name == caller then return true end
    end
    return false
end

-- panic(vehicleId, { threatPosition = {x,y,z}, threatKind = "player"|"npc"|"vehicle",
--   threatId = id, durationMilliseconds = ms }) -> view, or nil, reason
-- panicState(vehicleId) -> view, or nil, reason
--
-- For a server resource the operator listed in `panicResources`; any other
-- caller is refused with `forbidden_resource`, and a car this resource does
-- not track with `not_traffic_vehicle`. The view is { vehicleId, request,
-- status, reason, durationMs, remainingMs }; `request` is the token every
-- later outcome of this call is correlated to.
exports("panic", function(vehicleId, options)
    if not panicCallerApproved(GetInvokingResource()) then return nil, "forbidden_resource" end
    return requestPanic(vehicleId, options)
end)

exports("panicState", function(vehicleId)
    if not panicCallerApproved(GetInvokingResource()) then return nil, "forbidden_resource" end
    return panicState(vehicleId)
end)

-- Reset clears this resource's own fleet and nothing else: every vehicle it
-- created and every driver NPC it owns, whether or not the ledger still tracks
-- them.
--
-- The ledger alone is not enough to answer "what did this resource create".
-- `retire` deliberately hands a released wreck or a player-occupied car to the
-- canonical registry and drops its ledger entry, and the monitor drops an entry
-- whose car has vanished, so a ledger-only sweep would leave exactly those
-- bodies -- and, in the vanished case, their driver peds -- in the world while
-- claiming the traffic was cleared. The canonical registry is therefore the
-- source of truth for the vehicles, filtered on the creating resource, and the
-- ledger is joined in where it still has an entry: it carries the driver id, the
-- corridor reservation and the profile name the log reports. The filter is
-- applied twice: once when the registry is walked and again immediately before
-- each car is stopped, emptied or deleted, because the walk yields and a row
-- read before that gap is not evidence of who owns the car now.
--
-- Occupied traffic cars ARE in scope -- the panel's confirmation says so -- and
-- each occupant is put on their feet through the canonical seat API before the
-- body goes, whether the car is still tracked or was handed over earlier.
--
-- Settings survive a reset; only the run's own state is cleared: the fleet, the
-- corridor reservations, the quarantine sets, the ground-failure counts and the
-- population bag's position. The caller switches generation back on explicitly
-- (this is a reset of the traffic, not of the operator's configuration), so a
-- reset really does resume spawning.
--
-- The deletion yields between chunks, so a second reset can be scheduled into
-- the middle of the first one. It is refused rather than interleaved: the two
-- would otherwise clear each other's `resetting` flag and each clear a fleet
-- the other was still walking, and a car created in the gap would survive a
-- reset that claimed to have removed everything.
local function resetFleet()
    if resetting then return nil, "a reset is already running" end
    -- Fence first: a pass parked at a scan or a ground probe holds a selection
    -- whose corridor reservation is about to be released under it.
    generation = generation + 1
    resetting = true

    -- Everything this resource owns, per the canonical registry. Chunked with
    -- Wait(0) like the deletion below: the registry holds every vehicle on the
    -- server, so this walk is not bounded by this resource's own fleet.
    local mine = {}
    local registry = Open77.vehicles.all()
    local work = 0
    for index = 1, #registry do
        local vehicle = registry[index]
        if type(vehicle) == "table"
            and vehicle.resource == GetCurrentResourceName() then
            local id = tonumber(vehicle.id)
            if id then mine[id] = true end
        end
        work = work + 1
        if work >= COMMAND_WORK_PER_RESUME and index < #registry then
            work = 0
            Wait(0)
        end
    end

    local removedVehicles, removedDrivers, ejected, failed = 0, 0, 0, 0

    -- Ledger entries the registry no longer agrees with: a car that has gone
    -- (the monitor would clear it on its next tick) or one the registry now
    -- attributes to another resource. Neither is a target -- the second is named
    -- rather than skipped in silence -- and both give up their corridor
    -- reservation here, so nothing is left holding a candidate for the rest of
    -- the run. Dropping the entry for a foreign car is deliberate: it is not
    -- this resource's to retire, and the monitor must not judge it.
    for vehicleId, entry in pairs(cars) do
        local vehicle = Open77.vehicles.get(vehicleId)
        if not vehicle then
            releaseTracking(vehicleId, entry)
        elseif type(vehicle.resource) == "string"
            and vehicle.resource ~= GetCurrentResourceName() then
            failed = failed + 1
            log("reset: left car %s alone, it was created by %s",
                tostring(vehicleId), vehicle.resource)
            releaseTracking(vehicleId, entry)
        end
    end

    local ids = {}
    for vehicleId in pairs(mine) do ids[#ids + 1] = vehicleId end
    table.sort(ids)
    work = 0
    for index = 1, #ids do
        local vehicleId = ids[index]
        local entry = cars[vehicleId]
        -- Ownership is read HERE, before anything is stopped, ejected from or
        -- deleted: the walk that built this list yields, so a row read before the
        -- gap is not evidence of who owns the car now. A car that has turned out
        -- to belong to somebody else is not stopped, not emptied and not removed.
        local vehicle = Open77.vehicles.get(vehicleId)
        local owner = vehicle and vehicle.resource or nil
        local owned = type(owner) ~= "string" or owner == GetCurrentResourceName()
        if not owned then
            failed = failed + 1
            log("reset: left car %s alone, it was created by %s", tostring(vehicleId), owner)
            vehicle = nil
        end
        if entry and owned then
            if releaseDriver(vehicleId, entry) then removedDrivers = removedDrivers + 1 end
        elseif vehicle then
            -- A car the ledger has already released -- a wreck or a handed-over
            -- occupied car. Its driver went with it, but a task that still names
            -- one is detached, and any ped this resource still owns is removed
            -- by the ownership-scoped sweep below.
            Open77.vehicles.ai.stop(vehicleId)
            Open77.vehicles.ai.removeDriver(vehicleId)
        end
        if vehicle then
            -- The occupant leaves through the canonical seat request, and the
            -- registry publishes the seat's own fate when the vehicle is
            -- removed, so nobody is left seated in a car that no longer exists.
            -- A player who has already left is not an occupant.
            for _, occupant in ipairs(vehicle.occupants or {}) do
                local playerId = tonumber(occupant.playerId)
                if playerId and playerId > 0 then
                    Open77.vehicles.forcePlayerOutOfVehicle(playerId, vehicleId)
                    ejected = ejected + 1
                end
            end
            if Open77.vehicles.remove(vehicleId) == true then
                removedVehicles = removedVehicles + 1
            else
                failed = failed + 1
                log("reset: could not remove car %s", tostring(vehicleId))
            end
        end
        if entry then releaseTracking(vehicleId, entry) end
        work = work + 1
        if work >= COMMAND_WORK_PER_RESUME and index < #ids then
            work = 0
            Wait(0)
        end
    end

    -- Drivers this resource still owns after the cars are gone: a ped whose car
    -- vanished before the monitor could take it out has no ledger entry left to
    -- name it, and this registry is the only place that knows it. It is
    -- owner-scoped, so it can only ever list this resource's own peds, and the
    -- row's own resource is checked as well.
    local npcs = Open77.npcs.all()
    work = 0
    for index = 1, #npcs do
        local npc = npcs[index]
        local npcId = type(npc) == "table" and tonumber(npc.id) or nil
        if npcId and npc.resource == GetCurrentResourceName() then
            if Open77.npcs.remove(npcId) == true then removedDrivers = removedDrivers + 1 end
        end
        work = work + 1
        if work >= COMMAND_WORK_PER_RESUME and index < #npcs then
            work = 0
            Wait(0)
        end
    end

    -- The ownership-scoped sweep above removed every kept corpse with the rest
    -- of this resource's peds; a ledger row whose body is gone has nothing left
    -- to remove. A row whose body somehow survived keeps its bounded cleanup.
    for driverId in pairs(corpses) do
        if Open77.npcs.get(driverId) == nil then corpses[driverId] = nil end
    end

    -- The quarantine sets, the scan allowance and the population bag ARE the
    -- reset: they describe the run, not a car, so they are dropped wholesale.
    rejectedCorridors = {}
    rejectedProfiles = {}
    for _, runtime in pairs(corridorRuntimeByBucket) do
        runtime.groundFailures = {}
        runtime.joinFailures = {}
        runtime.quarantineUntil = {}
        runtime.impactFailures = {}
        runtime.laneQuarantineUntil = {}
    end
    resetDeferrals()
    scanWork = 0
    refillPopulationBag()
    -- The ledger and the corridor reservations were settled per car above, by
    -- identity, rather than by wiping the tables: a car that somehow reached the
    -- ledger across this reset's own yields keeps its entry, its reservation and
    -- its retirement path instead of being orphaned by a wipe. Nothing should be
    -- able to do that -- creation is blocked for the whole reset and every
    -- parked pass is fenced -- so a residue is named rather than swallowed.
    local residue = 0
    for _ in pairs(cars) do residue = residue + 1 end
    if residue > 0 then
        log("reset: %d car(s) entered the ledger during the reset and keep their entries; the generation fence should have prevented that",
            residue)
    end
    resetting = false
    return removedVehicles, removedDrivers, ejected, failed
end

-- The value a `set` command carries, checked against the declaration before it
-- is handed to the host. The host validates the same way -- this is the copy
-- that can refuse a pair of settings whose relation no single key's bounds
-- express, and it is what keeps an invalid request from reaching the fleet at
-- all.
local function proposedSetting(spec, raw)
    if spec.type == "boolean" then
        if raw == "true" or raw == "1" then return true end
        if raw == "false" or raw == "0" then return false end
        return nil, "expects true or false"
    end
    if spec.type == "text" then
        if type(raw) ~= "string" or #raw > 256 then return nil, "expects at most 256 characters" end
        return raw
    end
    local value = tonumber(raw)
    if not value or not finite(value) then return nil, "expects a number" end
    if spec.type == "integer" and value % 1 ~= 0 then return nil, "expects a whole number" end
    if spec.min and value < spec.min then
        return nil, ("must be at least %s"):format(tostring(spec.min))
    end
    if spec.max and value > spec.max then
        return nil, ("must be at most %s"):format(tostring(spec.max))
    end
    return value
end

local function setSetting(source, key, raw)
    local spec = TrafficSettings[key]
    if spec == nil then
        return panelResult(source, {
            ok = false, operation = "set", key = key,
            message = ("'%s' is not a traffic setting"):format(tostring(key)),
        })
    end
    local value, problem = proposedSetting(spec, raw)
    if value == nil then
        return panelResult(source, {
            ok = false, operation = "set", key = key,
            message = ("%s %s"):format(key, problem),
        })
    end
    local proposed = {}
    for name, current in pairs(CONFIG) do proposed[name] = current end
    proposed[key] = value
    local relation = relationMessage(proposed)
    if relation then
        return panelResult(source, {
            ok = false, operation = "set", key = key,
            message = relation,
        })
    end
    local accepted, message, pending = Open77.tunables.set(key, value)
    if accepted ~= true then
        return panelResult(source, {
            ok = false, operation = "set", key = key,
            message = tostring(message or "the value was refused"),
        })
    end
    -- The host owns the write and emits onTunableChanged for it; applying the
    -- value here as well only means the next spawn pass already reads it,
    -- instead of waiting for that event to be scheduled.
    applySetting(key, value)
    panelResult(source, {
        ok = true, operation = "set", key = key,
        message = ("%s = %s%s; saved, and it stays until it is changed or reset")
            :format(key, tostring(value), pending and " (waiting for its boundary)" or ""),
    })
end

RegisterCommand("traffic", function(source, args, raw)
    local sub = args[1]
    if sub == nil or sub == "none" or sub == "open" then
        local anchor = panelAnchor(source)
        if not anchor then
            return panelResult(source, {
                ok = false, operation = "open",
                message = "the traffic panel needs a ready, alive player behind the command",
            })
        end
        local radius, problem = panelRadius(args[2])
        if not radius then
            return panelResult(source, {ok = false, operation = "open", message = problem})
        end
        return panelSend(PANEL_OPEN, source, panelSnapshot(anchor, radius))
    end

    if sub == "state" then
        local anchor = panelAnchor(source)
        if not anchor then
            return panelResult(source, {
                ok = false, operation = "state",
                message = "the traffic panel needs a ready, alive player behind the command",
            })
        end
        local radius, problem = panelRadius(args[2])
        if not radius then
            return panelResult(source, {ok = false, operation = "state", message = problem})
        end
        return panelSend(PANEL_DATA, source, panelSnapshot(anchor, radius))
    end

    if sub == "set" then
        if args[2] == nil or args[3] == nil then
            return panelResult(source, {
                ok = false, operation = "set",
                message = "usage: traffic set <key> <value>",
            })
        end
        return setSetting(source, args[2], args[3])
    end

    if sub == "pattern" then
        local pattern = args[2]
        if pattern ~= "default" and pattern ~= "stop" then
            return panelResult(source, {
                ok = false, operation = "pattern", requested = tostring(pattern),
                message = "pattern must be default or stop; panic is its own command",
            })
        end
        local anchor = panelAnchor(source)
        if not anchor then
            return panelResult(source, {
                ok = false, operation = "pattern",
                message = "the traffic panel needs a ready, alive player behind the command",
            })
        end
        local radius, problem = panelRadius(args[3])
        if not radius then
            return panelResult(source, {ok = false, operation = "pattern", message = problem})
        end
        return panelResult(source, applyPattern(anchor, pattern, radius))
    end

    if sub == "panic" then
        local anchor = panelAnchor(source)
        if not anchor then
            return panelResult(source, {
                ok = false, operation = "panic",
                message = "the traffic panel needs a ready, alive player behind the command",
            })
        end
        local radius, problem = panelRadius(args[2])
        if not radius then
            return panelResult(source, {ok = false, operation = "panic", message = problem})
        end
        return panelResult(source, applyPanic(anchor, radius, tonumber(source)))
    end

    if sub == "reset" then
        -- A reset is destructive and irreversible for the cars it removes, so
        -- the word is required rather than assumed: a bare `traffic reset`
        -- refuses.
        if args[2] == nil or tostring(args[2]):lower() ~= "confirm" then
            return panelResult(source, {
                ok = false, operation = "reset",
                message = "usage: traffic reset confirm -- this deletes every car and driver this resource owns",
            })
        end
        -- A reset yields between its bounded chunks, so a second one can be
        -- scheduled into the middle of the first. Refuse it here -- before the
        -- generation is fenced, before generation is switched back on and
        -- before the registry is read -- or the two would clear each other's
        -- flag and each clear a fleet the other was still walking, and a car
        -- created in the gap would outlive a reset that claimed to have removed
        -- everything.
        if resetting then
            return panelResult(source, {
                ok = false, operation = "reset",
                message = "a reset is already running; it has not finished deleting the fleet",
            })
        end
        -- Explicitly switch generation on, through the same validated, persisted
        -- path the panel uses: a reset resumes spawning even if traffic was
        -- switched off before it. The host owns that value, so a refused write
        -- refuses the reset: the fleet and the configuration are left exactly as
        -- they were rather than being cleared on the strength of a write that
        -- did not happen.
        local accepted, message = Open77.tunables.set("enabled", true)
        if accepted ~= true then
            return panelResult(source, {
                ok = false, operation = "reset",
                message = ("the reset was refused: generation could not be switched on (%s)")
                    :format(tostring(message or "the host refused the write")),
            })
        end
        applySetting("enabled", true)
        local removedVehicles, removedDrivers, ejected, failed = resetFleet()
        if removedVehicles == nil then
            -- The guard above already answered this; repeating it here is what
            -- keeps a race from reaching the result formatting below with nil
            -- counts.
            return panelResult(source, {
                ok = false, operation = "reset",
                message = "a reset is already running; it has not finished deleting the fleet",
            })
        end
        local parts = {
            ("removed %d car(s) and %d driver(s)"):format(removedVehicles, removedDrivers),
        }
        if ejected > 0 then parts[#parts + 1] = ("%d occupant(s) sent out on foot"):format(ejected) end
        if failed > 0 then parts[#parts + 1] = ("%d could not be removed"):format(failed) end
        parts[#parts + 1] = "settings kept; generation restarted"
        panelResult(source, {
            ok = failed == 0, operation = "reset",
            removedVehicles = removedVehicles, removedDrivers = removedDrivers,
            failed = failed, message = table.concat(parts, "; "),
        })
        return
    end

    panelResult(source, {
        ok = false, operation = "traffic",
        message = ("unknown traffic command '%s'"):format(tostring(sub)),
    })
end, true)

RegisterCommand("traffic.status", function()
    local rejectedCorridorCount = 0
    for _ in pairs(rejectedCorridors) do rejectedCorridorCount = rejectedCorridorCount + 1 end
    local rejectedProfileCount = 0
    for _ in pairs(rejectedProfiles) do rejectedProfileCount = rejectedProfileCount + 1 end
    local active, total = populationCounts()
    local corpseCount = 0
    for _ in pairs(corpses) do corpseCount = corpseCount + 1 end
    local capacity = Open77.vehicles.ai.capacity()
    log("status: %d active / %d total car(s), max %d, admitted budget %d, core %d, per-simulator %d; %d span(s) with %d spawn sample(s); %d sample(s), %d/%d profile(s) rejected; %d killed driver(s) awaiting corpse cleanup",
        active, total, CONFIG.carsGlobal, currentBudget(activePlayers(), capacity),
        capacity.globalUsed, capacity.perSimulatorLimit,
        SPANS.spanCount, SPANS.sampleCount, rejectedCorridorCount, rejectedProfileCount, #POPULATION, corpseCount)
end, true)

-- The overlay is client-only (`client/esp.lua`), and the client Lua host has
-- no RegisterCommand: this only relays the toggle to the player who typed it.
RegisterCommand("traffic.esp", function(source)
    local player = tonumber(source)
    if not player or player <= 0 then
        return log("traffic.esp draws on a player's own screen; run it in game")
    end
    local sent, reason = TriggerClientEvent("open77_traffic:esp", player)
    if sent == false then log("esp toggle to %d failed: %s", player, tostring(reason)) end
end, true)

AddEventHandler("onResourceStop", function(name)
    if name ~= GetCurrentResourceName() then return end
    stopping = true
    generation = generation + 1
    -- Stop callbacks cannot rely on another scheduler turn. Preserve eligible
    -- passenger cars before host resource cleanup; the host removes other cars.
    for vehicleId, entry in pairs(cars) do
        if playerOccupied(Open77.vehicles.get(vehicleId)) then
            releaseDriver(vehicleId, entry)
            Open77.vehicles.setPersistent(vehicleId, false)
            Open77.vehicles.setDespawnWhenUnobserved(vehicleId, true)
            releaseTracking(vehicleId, entry)
        end
    end
end)
