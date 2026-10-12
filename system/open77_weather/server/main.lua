-- Authoritative multiplayer clock and weather state.
--
-- Clients can request snapshots but cannot submit mutations. Administrative
-- changes enter through restricted RegisterCommand handlers, so the dedicated
-- server resolves `command.weather.*` against the authenticated player's ACL.
--
-- This file is also the implementation behind the platform facade
-- `Open77.environment.*` on the server: the host prelude calls the
-- `environment.*` exports at the bottom of this file synchronously, in this VM.
-- The authority stayed here rather than moving into a C# service because the
-- only code able to move a sky is the CLIENT projection, which ships in this
-- same resource -- so a host-owned authority would guarantee nothing the
-- resource does not already guarantee, and would duplicate a reload-surviving
-- implementation that already answers late joiners.

local Config, Clock = Open77WeatherConfig, Open77WeatherClock
local EVENT_REQUEST = "open77:weather:request"
local EVENT_SYNC = "open77:weather:sync"
-- The scope key a client compares against. `default` is every routing bucket
-- that has no override of its own.
local DEFAULT_SCOPE = "default"
local MAX_OVERRIDES = 64
local lastSyncRequest = {}

-- The host-wide `onEnvironmentChanged` door. Feature-detected because a server
-- running an older host has no `Open77.environment` on this side at all, and
-- this resource must still hold the authority there.
local publishChange = type(Open77.environment) == "table"
    and type(Open77.environment.publishChange) == "function"
    and Open77.environment.publishChange or nil

local CHAT_SUGGESTIONS = {
    { command = "/weather", help = "Show the synchronized time and weather state.", parameters = {} },
    { command = "/weather.status", help = "Show the synchronized time and weather state.", parameters = {} },
    { command = "/weather.time", help = "Show the synchronized server clock.", parameters = {} },
    { command = "/weather.time.set", help = "Set the authoritative server time.", parameters = {
        { name = "HH:MM[:SS]", help = "24-hour time, for example 21:30:00." }
    } },
    { command = "/weather.time.freeze", help = "Freeze the authoritative server clock.", parameters = {} },
    { command = "/weather.time.resume", help = "Resume the authoritative server clock.", parameters = {} },
    { command = "/weather.rate", help = "Set game seconds elapsed per real second.", parameters = {
        { name = "rate", help = "A number from 0 to 120." }
    } },
    { command = "/weather.set", help = "Apply a synchronized weather preset.", parameters = {
        { name = "weather", help = "For example sunny, rain, fog, or sandstorm." },
        { name = "transitionSeconds", optional = true }
    } },
    { command = "/weather.random", help = "Enable or disable random weather events.", parameters = {
        { name = "on|off" }
    } },
    { command = "/weather.next", help = "Trigger the next weighted weather event.", parameters = {} },
}

RegisterNetEvent("chat:ready", function()
    TriggerClientEvent("chat:addSuggestions", source, CHAT_SUGGESTIONS)
end)

local function nowMs()
    return math.floor(Open77.time.monotonic() * 1000)
end

local presets, presetList = {}, {}
for _, definition in ipairs(Config.presets) do
    presets[string.lower(definition.name)] = definition
    presets[string.lower(definition.preset)] = definition
    presetList[#presetList + 1] = definition
end

local function resolveWeather(value)
    if type(value) ~= "string" then return nil end
    local key = string.lower(value)
    key = Config.aliases[key] or key
    return presets[key]
end

local initial = assert(Clock.fromHms(
    Config.startupTime.hour, Config.startupTime.minute, Config.startupTime.second))
local authorityEpoch = 0
local initialized = false

-- ---------------------------------------------------------------------------
-- Revisions are drawn from ONE counter shared by every scope, and that is what
-- makes a per-bucket override possible at all.
--
-- A client accepts a snapshot only when its revision is >= the last one it
-- applied. If each scope counted for itself, a player moving from a bucket
-- sitting at revision 40 into one whose last change was revision 12 would reject
-- that bucket's snapshots -- including its heartbeats -- forever, and stay on
-- the sky of a bucket they had left. One monotonic counter makes every snapshot
-- any client can receive newer than every snapshot it has already applied.
local revisionCounter, weatherRevisionCounter = 1, 1

local function nextRevision()
    revisionCounter = revisionCounter + 1
    return revisionCounter
end

local function nextWeatherRevision()
    weatherRevisionCounter = weatherRevisionCounter + 1
    return weatherRevisionCounter
end

local function newScope()
    return {
        revision = revisionCounter,
        weatherRevision = weatherRevisionCounter,
        baseSeconds = initial,
        anchorMs = 0,
        rate = Config.timeScale,
        frozen = Config.timeFrozen == true,
        weather = assert(resolveWeather(Config.initialWeather)).name,
        randomWeather = Config.randomWeather == true,
        weatherChangedAtMs = 0,
        transitionSeconds = 0,
        nextWeatherAtMs = 0,
    }
end

-- The default scope, under its original name: every read below is unchanged.
local state = newScope()
-- [bucket] = scope. Empty on every server that never asks for an override, and
-- the delivery path below stays a single broadcast while it is.
local overrides, overrideCount = {}, 0

local function validBucket(bucket)
    return type(bucket) == "number" and bucket == bucket and bucket >= 0
        and bucket % 1 == 0 and bucket <= 4294967295
end

local function scopeKey(bucket)
    if bucket == nil then return DEFAULT_SCOPE end
    return "bucket:" .. string.format("%d", bucket)
end

local function overriddenBuckets()
    local list = {}
    for bucket in pairs(overrides) do list[#list + 1] = bucket end
    table.sort(list)
    return list
end

local function currentSeconds(scope, atMs)
    return Clock.at(scope.baseSeconds, scope.anchorMs, scope.rate, scope.frozen, atMs or nowMs())
end

-- ---------------------------------------------------------------------------
-- Surviving a reload
--
-- Everything above is a *default*, not a state: noon, sunny, random weather on.
-- They are right exactly once, at boot. A reload builds a brand-new Lua VM and
-- runs this file again from the top, so without the two functions below the
-- authority silently re-adopts those defaults and broadcasts them -- and because
-- a fresh VM also mints a *higher* `authorityEpoch`, every client accepts the
-- reverted snapshot rather than rejecting it as stale.
--
-- That is data loss, not a reset. A server whose `startup.commands` pinned
-- 20:30 / lightclouds / random off is a competitive server that pinned them
-- because lighting is a fairness variable: one match in fog and the next in noon
-- glare are materially different games. `startup.commands` runs once per
-- process, so nothing re-applied the pin, and on a dev server a one-second file
-- watcher turns *any* edit to *any* resource into that silent revert.
--
-- `Open77.state` is the host-owned bag that outlives this VM. It survives a
-- reload and deliberately does not survive the resource going down, so `stop`,
-- `restart` and `refresh` still bring the authority up at its configured
-- defaults -- and the server re-asserts `startup.commands` for a resource that
-- comes back up carrying nothing.
--
-- What is carried is every scope's whole snapshot, `authorityEpoch` and the two
-- revision counters included. Preserving those is the point: a client that sees
-- the same epoch and a revision that only ever grows cannot tell the reload
-- happened, which is the correct answer -- the authority did not restart, its
-- code was swapped underneath it.
local CARRIED_FIELDS = {
    "revision", "weatherRevision", "baseSeconds", "anchorMs", "rate",
    "weatherChangedAtMs", "transitionSeconds", "nextWeatherAtMs",
}

local function carryScope(scope)
    local carried = {
        frozen = scope.frozen,
        weather = scope.weather,
        randomWeather = scope.randomWeather,
    }
    for _, field in ipairs(CARRIED_FIELDS) do carried[field] = scope[field] end
    return carried
end

-- Returns a scope, or nil plus the sentence to print. Every field is validated:
-- a preset the operator has since removed from `Config.presets`, or a snapshot
-- from an incompatible shape, must fall back to the configured defaults rather
-- than leave the authority holding a value it cannot resolve.
local function adoptScope(carried)
    if type(carried) ~= "table" then return nil, "a scope is not a table" end
    local weather = resolveWeather(carried.weather)
    if weather == nil then
        return nil, "preset '" .. tostring(carried.weather) .. "' is no longer configured"
    end
    for _, field in ipairs(CARRIED_FIELDS) do
        local value = carried[field]
        -- `value ~= value` is the NaN test; a NaN anchor would freeze the clock
        -- silently rather than loudly.
        if type(value) ~= "number" or value ~= value then
            return nil, "field '" .. field .. "' is not a number"
        end
    end
    if carried.rate < 0 or carried.rate > 120 then return nil, "rate is out of range" end
    local scope = newScope()
    for _, field in ipairs(CARRIED_FIELDS) do scope[field] = carried[field] end
    scope.baseSeconds = Clock.normalize(scope.baseSeconds)
    scope.weather = weather.name
    scope.frozen = carried.frozen == true
    scope.randomWeather = carried.randomWeather == true
    return scope
end

local function saveState()
    if not initialized then return end
    local carried = {
        -- Shape guard. A reload can change this file, so a snapshot written by
        -- the previous version of this code is untrusted input: bump `protocol`
        -- in shared/config.lua whenever the shape below changes and the stale
        -- snapshot is refused instead of half-adopted.
        protocol = Config.protocol,
        authorityEpoch = authorityEpoch,
        revisionCounter = revisionCounter,
        weatherRevisionCounter = weatherRevisionCounter,
        default = carryScope(state),
        -- An array, not a map: this round-trips through JSON, where an integer
        -- key is not a shape worth relying on.
        overrides = {},
    }
    for bucket, scope in pairs(overrides) do
        carried.overrides[#carried.overrides + 1] = { bucket = bucket, scope = carryScope(scope) }
    end
    Open77.state.save(carried)
end

local function restoreState()
    local carried = Open77.state.load()
    if type(carried) ~= "table" then return false end
    if carried.protocol ~= Config.protocol then
        print("[open77_weather] carried state ignored: protocol " ..
            tostring(carried.protocol) .. " is not " .. tostring(Config.protocol))
        return false
    end
    if type(carried.authorityEpoch) ~= "number" or carried.authorityEpoch < 0 then return false end

    local adopted, failure = adoptScope(carried.default)
    if adopted == nil then
        print("[open77_weather] carried state ignored: " .. failure)
        return false
    end

    local restored, restoredCount = {}, 0
    if carried.overrides ~= nil then
        if type(carried.overrides) ~= "table" then return false end
        for _, entry in ipairs(carried.overrides) do
            if type(entry) ~= "table" or not validBucket(entry.bucket) then
                print("[open77_weather] carried state ignored: a bucket override has no bucket")
                return false
            end
            local scope, reason = adoptScope(entry.scope)
            if scope == nil then
                print("[open77_weather] carried state ignored: bucket " ..
                    string.format("%d", entry.bucket) .. ", " .. reason)
                return false
            end
            restored[entry.bucket] = scope
            restoredCount = restoredCount + 1
        end
    end

    state, overrides, overrideCount = adopted, restored, restoredCount
    authorityEpoch = carried.authorityEpoch
    -- Never let a counter come back lower than a revision some client already
    -- applied: the whole acceptance rule downstream is "revisions only grow".
    revisionCounter = math.max(tonumber(carried.revisionCounter) or 0, state.revision)
    weatherRevisionCounter = math.max(
        tonumber(carried.weatherRevisionCounter) or 0, state.weatherRevision)
    for _, scope in pairs(overrides) do
        revisionCounter = math.max(revisionCounter, scope.revision)
        weatherRevisionCounter = math.max(weatherRevisionCounter, scope.weatherRevision)
    end
    initialized = true
    return true
end

-- A fresh server Lua VM is prepared before its first scheduler tick, so its
-- injected monotonic clock still reads zero at file scope. Anchor lazily on the
-- first real tick; otherwise a hot-reload would add the whole server uptime to
-- a brand-new noon clock.
--
-- `anchorMs` is host-monotonic and therefore process-wide, so a restored anchor
-- from a previous generation stays meaningful across the reload -- which is why
-- a restore can mark the state initialised without re-anchoring anything.
local function ensureInitialized()
    if initialized then return end
    local atMs = nowMs()
    state.anchorMs = atMs
    state.weatherChangedAtMs = atMs
    state.nextWeatherAtMs = atMs + Config.initialWeatherDurationSeconds * 1000
    authorityEpoch = math.floor(Open77.time.monotonic() * 1000000)
    initialized = true
    -- Persist the anchor immediately: without this a reload before the first
    -- mutation would still send the time-of-day back to noon on a server that
    -- pinned nothing at all.
    saveState()
end

-- Adopt whatever the previous generation was holding, before anything can read
-- or broadcast a default.
local restoredFromReload = restoreState()

-- ---------------------------------------------------------------------------
-- Snapshots

local function snapshotOf(scope, bucket, atMs, reason)
    ensureInitialized()
    atMs = atMs or nowMs()
    local weather = assert(resolveWeather(scope.weather))
    local transitionDurationMs = scope.transitionSeconds * 1000
    local transitionElapsedMs = math.max(0, atMs - scope.weatherChangedAtMs)
    return {
        protocol = Config.protocol,
        authorityEpoch = authorityEpoch,
        revision = scope.revision,
        weatherRevision = scope.weatherRevision,
        -- Which environment this snapshot describes. A client that receives a
        -- different scope than the one it is projecting adopts unconditionally:
        -- it has been moved to another world, not handed a newer reading of the
        -- one it was in.
        scope = scopeKey(bucket),
        bucket = bucket,
        secondsOfDay = currentSeconds(scope, atMs),
        rate = scope.rate,
        frozen = scope.frozen,
        weather = weather.name,
        weatherPreset = weather.preset,
        weatherPriority = Config.weatherPriority,
        transitionSeconds = scope.transitionSeconds,
        weatherTransitionRemainingMs = math.max(0, transitionDurationMs - transitionElapsedMs),
        randomWeather = scope.randomWeather,
        nextWeatherInMs = scope.randomWeather and math.max(0, scope.nextWeatherAtMs - atMs) or nil,
        reason = reason or "sync",
    }
end

-- The canonical state a caller reads, and the `onEnvironmentChanged` payload:
-- the wire snapshot plus everything a HUD would otherwise have to compute.
local function describe(scope, bucket, reason, atMs)
    local value = snapshotOf(scope, bucket, atMs, reason)
    local hour, minute, second = Clock.toHms(value.secondsOfDay)
    value.hour, value.minute, value.second = hour, minute, second
    value.timeFrozen = value.frozen
    -- Server-side "weather frozen" is exactly "the weighted scheduler is off":
    -- the preset stays until something sets another one. The client-side lock
    -- against a vanilla controller is unconditional and is not an operator
    -- choice, so it is not what this flag reports.
    value.weatherFrozen = not scope.randomWeather
    value.buckets = overriddenBuckets()
    return value
end

local function scopeOfPlayer(playerId)
    local bucket = Open77.routingBuckets.getPlayer(playerId)
    if bucket ~= nil and overrides[bucket] ~= nil then return overrides[bucket], bucket end
    return state, nil
end

-- ---------------------------------------------------------------------------
-- Delivery
--
-- With no override this is EXACTLY what it always was: one reliable broadcast to
-- -1, once per mutation and once per heartbeat. An override makes a broadcast
-- wrong -- it reaches the overridden bucket too, carrying a higher revision, and
-- clobbers it -- so the default scope falls back to a per-player fan-out, and
-- only then. Measured cost of an override: one TriggerClientEvent per connected
-- player per heartbeat instead of one for the whole server.
local function publishScope(bucket, reason)
    ensureInitialized()
    local scope = bucket == nil and state or overrides[bucket]
    if scope == nil then return nil, "unknown_bucket" end
    local atMs = nowMs()
    local value = snapshotOf(scope, bucket, atMs, reason)
    if bucket ~= nil then
        for _, playerId in ipairs(Open77.players.inBucket(bucket) or {}) do
            TriggerClientEvent(EVENT_SYNC, playerId, value)
        end
    elseif overrideCount == 0 then
        TriggerClientEvent(EVENT_SYNC, -1, value)
    else
        for _, playerId in ipairs(Open77.players.all() or {}) do
            if select(2, scopeOfPlayer(playerId)) == nil then
                TriggerClientEvent(EVENT_SYNC, playerId, value)
            end
        end
    end
    TriggerEvent("open77:weather:state", value)
    return value
end

local function publishTo(playerId, reason, requestId)
    ensureInitialized()
    local scope, bucket = scopeOfPlayer(playerId)
    local value = snapshotOf(scope, bucket, nowMs(), reason)
    TriggerClientEvent(EVENT_SYNC, playerId, value, requestId)
    TriggerEvent("open77:weather:state", value)
    return value
end

-- Announce a real change host-wide. Never on a heartbeat and never on a sync
-- reply: `onEnvironmentChanged` means the environment changed.
local function announce(scope, bucket, reason, atMs)
    local value = describe(scope, bucket, reason, atMs)
    if publishChange ~= nil then publishChange(value) end
    return value
end

local function rebase(scope, atMs)
    scope.baseSeconds = currentSeconds(scope, atMs)
    scope.anchorMs = atMs
end

local function scheduleWeather(scope, definition, atMs)
    local minimum = math.floor(definition.minSeconds)
    local maximum = math.floor(definition.maxSeconds)
    scope.nextWeatherAtMs = atMs + math.random(minimum, maximum) * 1000
end

-- ---------------------------------------------------------------------------
-- Scope selection
--
-- A setter that names a bucket CREATES the override if it does not exist yet,
-- seeded from the default scope as it reads right now -- so a race gamemode that
-- only pins the time keeps whatever weather the session had, and a scope created
-- at dusk does not start at noon.
local function openScope(bucket)
    if bucket == nil then return state, nil end
    if not validBucket(bucket) then return nil, "invalid_bucket" end
    local scope = overrides[bucket]
    if scope ~= nil then return scope, nil end
    if overrideCount >= MAX_OVERRIDES then return nil, "too_many_environment_overrides" end
    ensureInitialized()
    local atMs = nowMs()
    scope = {}
    for key, value in pairs(state) do scope[key] = value end
    scope.baseSeconds = currentSeconds(state, atMs)
    scope.anchorMs = atMs
    overrides[bucket] = scope
    overrideCount = overrideCount + 1
    return scope, nil
end

local function findScope(bucket)
    if bucket == nil then return state, nil end
    if not validBucket(bucket) then return nil, "invalid_bucket" end
    local scope = overrides[bucket]
    if scope == nil then return nil, "unknown_bucket" end
    return scope, nil
end

-- ---------------------------------------------------------------------------
-- Mutators
--
-- Every mutator anchors first. `saveState` refuses to persist an unanchored
-- state -- `anchorMs` is still zero before the first scheduler slice, and a
-- snapshot carrying that would restart the day at the anchor on the next reload
-- -- so a mutator that skipped this would silently persist nothing.
local function setTime(seconds, reason, bucket)
    ensureInitialized()
    local scope, failure = openScope(bucket)
    if scope == nil then return nil, failure end
    scope.baseSeconds = Clock.normalize(seconds)
    scope.anchorMs = nowMs()
    scope.revision = nextRevision()
    saveState()
    local value = publishScope(bucket, reason or "time_set")
    TriggerEvent("open77:weather:timeChanged", value)
    return announce(scope, bucket, reason or "time_set")
end

local function setFrozen(frozen, reason, bucket)
    ensureInitialized()
    local scope, failure = openScope(bucket)
    if scope == nil then return nil, failure end
    frozen = frozen == true
    local atMs = nowMs()
    rebase(scope, atMs)
    scope.frozen = frozen
    scope.revision = nextRevision()
    saveState()
    reason = reason or (frozen and "time_frozen" or "time_resumed")
    local value = publishScope(bucket, reason)
    TriggerEvent("open77:weather:timeChanged", value)
    return announce(scope, bucket, reason)
end

local function setRate(rate, reason, bucket)
    ensureInitialized()
    rate = tonumber(rate)
    if rate == nil or rate ~= rate or rate < 0 or rate > 120 then
        return nil, "rate_must_be_between_0_and_120"
    end
    local scope, failure = openScope(bucket)
    if scope == nil then return nil, failure end
    local atMs = nowMs()
    rebase(scope, atMs)
    scope.rate = rate
    scope.revision = nextRevision()
    saveState()
    reason = reason or "rate_changed"
    local value = publishScope(bucket, reason)
    TriggerEvent("open77:weather:timeChanged", value)
    return announce(scope, bucket, reason)
end

local function setWeather(name, transition, reason, bucket)
    ensureInitialized()
    local definition = resolveWeather(name)
    if definition == nil then return nil, "unknown_weather" end
    if transition ~= nil and tonumber(transition) == nil then return nil, "invalid_transition" end
    transition = transition ~= nil and tonumber(transition) or definition.transitionSeconds
    if transition ~= transition or transition < 0 or transition > 300 then
        return nil, "transition_must_be_between_0_and_300"
    end
    local scope, failure = openScope(bucket)
    if scope == nil then return nil, failure end
    local atMs = nowMs()
    scope.weather = definition.name
    scope.weatherChangedAtMs = atMs
    scope.transitionSeconds = transition
    scheduleWeather(scope, definition, atMs)
    scope.revision = nextRevision()
    scope.weatherRevision = nextWeatherRevision()
    saveState()
    reason = reason or "weather_changed"
    local value = publishScope(bucket, reason)
    TriggerEvent("open77:weather:weatherChanged", value)
    return announce(scope, bucket, reason)
end

-- Both entry points for the random scheduler -- the trusted server event and the
-- restricted console command -- go through here, so neither can forget to bump
-- the revision or to persist. `weather.random off` is the line a competitive
-- server pins, and losing it is what silently re-randomises the lighting.
local function setRandomWeather(enabled, reason, bucket)
    ensureInitialized()
    local scope, failure = openScope(bucket)
    if scope == nil then return nil, failure end
    scope.randomWeather = enabled == true
    if scope.randomWeather then
        scheduleWeather(scope, assert(resolveWeather(scope.weather)), nowMs())
    end
    scope.revision = nextRevision()
    saveState()
    publishScope(bucket, reason)
    return announce(scope, bucket, reason or "random_weather_changed")
end

-- Retire an override. The players still standing in that bucket must be told
-- with a revision newer than the one they last applied, or they keep the sky of
-- an environment that no longer exists -- hence the bump on the default scope.
local function clearBucket(bucket)
    if not validBucket(bucket) then return nil, "invalid_bucket" end
    if overrides[bucket] == nil then return nil, "unknown_bucket" end
    ensureInitialized()
    overrides[bucket] = nil
    overrideCount = overrideCount - 1
    state.revision = nextRevision()
    saveState()
    publishScope(nil, "bucket_cleared")
    return announce(state, nil, "bucket_cleared")
end

local function chooseNextWeather(scope)
    local candidates, total = {}, 0
    for _, definition in ipairs(presetList) do
        if definition.name ~= scope.weather and definition.weight > 0 then
            total = total + definition.weight
            candidates[#candidates + 1] = { definition = definition, ceiling = total }
        end
    end
    if total <= 0 then return resolveWeather(scope.weather) end
    local roll = math.random() * total
    for _, candidate in ipairs(candidates) do
        if roll < candidate.ceiling then return candidate.definition end
    end
    return candidates[#candidates].definition
end

local function output(source, raw, success, message)
    print(message)
    if source ~= nil and source > 0 then
        TriggerClientEvent("open77:command:result", source, raw or "", success == true, message)
    end
end

-- Byte-identical to what it has always printed while no override exists: an
-- operator's eye and three integration tests read this line.
local function statusText()
    local seconds = currentSeconds(state)
    local hour, minute, second = Clock.toHms(seconds)
    local line = string.format(
        "weather: time=%02d:%02d:%02d rate=%.2fx frozen=%s preset=%s random=%s revision=%d",
        hour, minute, second, state.rate, tostring(state.frozen), state.weather,
        tostring(state.randomWeather), state.revision)
    if overrideCount == 0 then return line end
    local labels = {}
    for _, bucket in ipairs(overriddenBuckets()) do
        local scope = overrides[bucket]
        local h, m, s = Clock.toHms(currentSeconds(scope))
        labels[#labels + 1] = string.format("%d@%02d:%02d:%02d/%s", bucket, h, m, s, scope.weather)
    end
    return line .. " overrides=" .. table.concat(labels, ",")
end

RegisterNetEvent(EVENT_REQUEST, function(requestId)
    requestId = tonumber(requestId)
    if requestId == nil or requestId < 1 or requestId % 1 ~= 0 then return end
    local requestedAt = nowMs()
    if lastSyncRequest[source] ~= nil and
       requestedAt - lastSyncRequest[source] < Config.minimumRequestIntervalMs then return end
    lastSyncRequest[source] = requestedAt
    publishTo(source, "request", requestId)
end)

-- A player who changes routing bucket changes environment, and the client's
-- staleness test is the revision: a move into a scope whose last change is older
-- than what that client already applied would be refused. Draw a fresh revision
-- for the scope being entered -- on the scope itself, not just on the packet, or
-- the scope's next heartbeat would carry the lower number and be refused in turn.
-- `weatherRevision` is deliberately NOT bumped: the client forces a weather
-- re-application on a scope change anyway, and bumping it would make everyone
-- else in that scope re-submit their preset for nothing.
AddEventHandler("onPlayerBucketChange", function(playerId)
    if overrideCount == 0 then return end
    playerId = tonumber(playerId)
    if playerId == nil or playerId <= 0 then return end
    local scope, bucket = scopeOfPlayer(playerId)
    scope.revision = nextRevision()
    saveState()
    TriggerClientEvent(EVENT_SYNC, playerId, snapshotOf(scope, bucket, nowMs(), "bucket_change"))
end)

-- Local server API for other trusted resources. Mutations are never registered
-- as network events, so a client cannot invoke these names directly.
AddEventHandler("open77:weather:requestState", function() publishScope(nil, "server_resource_request") end)
AddEventHandler("open77:weather:setTime", function(hour, minute, second)
    local seconds, reason = Clock.fromHms(hour, minute, second)
    if seconds then setTime(seconds, "server_resource_time")
    else print("[open77_weather] rejected setTime: " .. tostring(reason)) end
end)
AddEventHandler("open77:weather:setRate", function(rate)
    local _, reason = setRate(rate, "server_resource_rate")
    if reason then print("[open77_weather] rejected setRate: " .. reason) end
end)
AddEventHandler("open77:weather:setFrozen", function(frozen)
    setFrozen(frozen, "server_resource_freeze")
end)
AddEventHandler("open77:weather:setWeather", function(name, transition)
    local _, reason = setWeather(name, transition, "server_resource_weather")
    if reason then print("[open77_weather] rejected setWeather: " .. reason) end
end)
AddEventHandler("open77:weather:setRandomEnabled", function(enabled)
    setRandomWeather(enabled, "server_resource_random")
end)

-- ---------------------------------------------------------------------------
-- Server exports: the surface `Open77.environment.*` is a facade over.
--
-- They are the resource's public API and therefore reachable without
-- `world.environment`, exactly as the `open77:weather:set*` events above have
-- always been. The capability gates the platform facade, which is where a new
-- resource is told to go; closing the older doors would break every resource
-- already using them and is a separate, breaking decision.

exports("environment.getState", function(bucket)
    local scope, failure = findScope(bucket)
    if scope == nil then return nil, failure end
    return describe(scope, bucket, "query")
end)

exports("environment.setTime", function(hour, minute, second, bucket)
    local seconds, reason = Clock.fromHms(hour, minute, second)
    if seconds == nil then return nil, reason end
    return setTime(seconds, "api_time_set", bucket)
end)

exports("environment.setTimeFrozen", function(frozen, bucket)
    if type(frozen) ~= "boolean" then return nil, "invalid_argument" end
    return setFrozen(frozen, frozen and "api_time_frozen" or "api_time_resumed", bucket)
end)

exports("environment.setTimeRate", function(rate, bucket)
    return setRate(rate, "api_rate_changed", bucket)
end)

exports("environment.setWeather", function(preset, transitionSeconds, bucket)
    return setWeather(preset, transitionSeconds, "api_weather_changed", bucket)
end)

-- Server-side, freezing the weather means pinning the preset: the weighted
-- random scheduler stops drawing. Unfreezing reschedules it from now.
exports("environment.setWeatherFrozen", function(frozen, bucket)
    if type(frozen) ~= "boolean" then return nil, "invalid_argument" end
    return setRandomWeather(not frozen, frozen and "api_weather_frozen" or "api_weather_resumed", bucket)
end)

exports("environment.clearBucket", function(bucket)
    return clearBucket(bucket)
end)

-- ---------------------------------------------------------------------------
-- Commands. Unchanged: the same names, the same arguments, the same output, and
-- they drive the same mutators the exports do -- on the default scope, which is
-- what an operator typing `weather.set fog` means.

RegisterCommand("weather", function(source, _, raw)
    output(source, raw, true, statusText())
end, false)

RegisterCommand("weather.status", function(source, _, raw)
    output(source, raw, true, statusText())
end, false)

RegisterCommand("weather.time", function(source, _, raw)
    output(source, raw, true, statusText())
end, false)

RegisterCommand("weather.time.set", function(source, args, raw)
    if args.n ~= 1 then return output(source, raw, false, "usage: weather.time.set <HH:MM[:SS]>") end
    local seconds, reason = Clock.parse(args[1])
    if seconds == nil then return output(source, raw, false, "invalid time: " .. reason) end
    setTime(seconds, "command_time_set")
    output(source, raw, true, statusText())
end, true)

RegisterCommand("weather.time.freeze", function(source, args, raw)
    if args.n ~= 0 then return output(source, raw, false, "usage: weather.time.freeze") end
    setFrozen(true, "command_time_freeze")
    output(source, raw, true, statusText())
end, true)

RegisterCommand("weather.time.resume", function(source, args, raw)
    if args.n ~= 0 then return output(source, raw, false, "usage: weather.time.resume") end
    setFrozen(false, "command_time_resume")
    output(source, raw, true, statusText())
end, true)

RegisterCommand("weather.rate", function(source, args, raw)
    if args.n ~= 1 then return output(source, raw, false, "usage: weather.rate <0..120>") end
    local _, reason = setRate(args[1], "command_rate")
    if reason then return output(source, raw, false, reason) end
    output(source, raw, true, statusText())
end, true)

RegisterCommand("weather.set", function(source, args, raw)
    if args.n < 1 or args.n > 2 then
        return output(source, raw, false, "usage: weather.set <name|preset> [transitionSeconds]")
    end
    local _, reason = setWeather(args[1], args[2], "command_weather")
    if reason then return output(source, raw, false, reason) end
    output(source, raw, true, statusText())
end, true)

RegisterCommand("weather.random", function(source, args, raw)
    if args.n ~= 1 or (args[1] ~= "on" and args[1] ~= "off") then
        return output(source, raw, false, "usage: weather.random <on|off>")
    end
    setRandomWeather(args[1] == "on", "command_random")
    output(source, raw, true, statusText())
end, true)

RegisterCommand("weather.next", function(source, args, raw)
    if args.n ~= 0 then return output(source, raw, false, "usage: weather.next") end
    setWeather(chooseNextWeather(state).name, nil, "command_next")
    output(source, raw, true, statusText())
end, true)

CreateThread(function()
    -- The first scheduler tick supplies a process-specific monotonic value,
    -- avoiding an identical pseudo-random weather sequence on every boot.
    math.randomseed(math.floor(Open77.time.monotonic() * 1000000) % 2147483647)
    local nextHeartbeatAtMs = nowMs() + Config.heartbeatIntervalMs
    while true do
        Wait(Config.weatherSchedulerIntervalMs)
        ensureInitialized()
        local atMs = nowMs()
        local changed = {}
        if state.randomWeather and atMs >= state.nextWeatherAtMs then
            setWeather(chooseNextWeather(state).name, nil, "random_weather")
            changed[DEFAULT_SCOPE] = true
        end
        -- Snapshot the bucket list first: a mutator never adds or removes an
        -- override, but reading it once keeps the loop honest if one ever does.
        for _, bucket in ipairs(overriddenBuckets()) do
            local scope = overrides[bucket]
            if scope ~= nil and scope.randomWeather and atMs >= scope.nextWeatherAtMs then
                setWeather(chooseNextWeather(scope).name, nil, "random_weather", bucket)
                changed[scopeKey(bucket)] = true
            end
        end
        if atMs >= nextHeartbeatAtMs then
            -- A mutation already broadcast an equivalent snapshot this tick.
            if not changed[DEFAULT_SCOPE] then publishScope(nil, "heartbeat") end
            for _, bucket in ipairs(overriddenBuckets()) do
                if not changed[scopeKey(bucket)] then publishScope(bucket, "heartbeat") end
            end
            nextHeartbeatAtMs = atMs + Config.heartbeatIntervalMs
        end
    end
end)

-- The banner reports what the authority actually holds. It used to hard-code
-- noon, which after a reload was exactly the wrong thing to print: it agreed
-- with the reverted state instead of exposing it.
if restoredFromReload then
    print("[open77_weather] authority resumed across a reload -- " .. statusText())
else
    local bootHour, bootMinute, bootSecond = Clock.toHms(state.baseSeconds)
    print(string.format(
        "open77_weather authority ready at %02d:%02d:%02d; use weather.status",
        bootHour, bootMinute, bootSecond))
end
