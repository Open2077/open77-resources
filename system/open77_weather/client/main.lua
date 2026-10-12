-- Client projection of the dedicated server's clock and weather.
-- No client mutation event exists: this VM only requests and applies snapshots.

if type(Open77.environment) ~= "table" or type(Open77.environment.setTime) ~= "function" then
    print("[open77_weather] native environment API unavailable; restart Cyberpunk to activate it")
    return
end

local Config, Clock = Open77WeatherConfig, Open77WeatherClock
local EVENT_REQUEST = "open77:weather:request"
local EVENT_SYNC = "open77:weather:sync"

local state, requestSequence, requests = nil, 0, {}
local matchClock = nil -- owner-scoped, leased projection from Cordon server state
local lastAppliedSecond, lastWeatherRevision, stopped = nil, nil, false

local function nowMs()
    return math.floor(Open77.time.monotonic() * 1000)
end

local function requestSync()
    local requestedAt = nowMs()
    for id, sentAt in pairs(requests) do
        if requestedAt - sentAt > Config.syncIntervalMs * 4 then requests[id] = nil end
    end
    requestSequence = requestSequence + 1
    requests[requestSequence] = requestedAt
    local ok, reason = TriggerServerEvent(EVENT_REQUEST, requestSequence)
    if not ok then
        requests[requestSequence] = nil
        print("[open77_weather] sync request failed: " .. tostring(reason))
    end
    return ok, reason
end

local function validSnapshot(value)
    return type(value) == "table" and value.protocol == Config.protocol and
        -- Which environment the snapshot describes: `default`, or `bucket:<n>`
        -- for a routing bucket the server holds an override for.
        type(value.scope) == "string" and #value.scope > 0 and #value.scope <= 32 and
        type(value.authorityEpoch) == "number" and value.authorityEpoch >= 0 and
        type(value.revision) == "number" and value.revision >= 1 and value.revision % 1 == 0 and
        type(value.weatherRevision) == "number" and value.weatherRevision >= 1 and
        value.weatherRevision % 1 == 0 and
        type(value.secondsOfDay) == "number" and
        type(value.rate) == "number" and value.rate >= 0 and value.rate <= 120 and
        type(value.frozen) == "boolean" and type(value.weatherPreset) == "string" and
        type(value.weatherPriority) == "number" and value.weatherPriority >= 0 and
        value.weatherPriority % 1 == 0 and type(value.transitionSeconds) == "number" and
        value.transitionSeconds >= 0 and value.transitionSeconds <= 300 and
        type(value.weatherTransitionRemainingMs) == "number" and
        value.weatherTransitionRemainingMs >= 0 and value.weatherTransitionRemainingMs <= 300000
end

local function projectedSeconds(atMs)
    local now = atMs or nowMs()
    if matchClock ~= nil then
        if now <= matchClock.expiresAtMs then
            return Clock.at(matchClock.secondsOfDay, matchClock.anchorLocalMs, matchClock.rate, false, now)
        end
        matchClock = nil
        lastAppliedSecond = nil
    end
    if state == nil then return nil end
    return Clock.at(state.secondsOfDay, state.anchorLocalMs, state.rate, state.frozen, atMs or nowMs())
end

local function applyTime(allowRewind)
    local expected = projectedSeconds()
    if expected == nil then return end
    local whole = math.floor(expected)

    -- The native SetGameTimeByHMS chooses the next occurrence. A stale packet
    -- that is one second behind must therefore not turn into a full-day jump.
    if lastAppliedSecond ~= nil and not allowRewind then
        local forward = Clock.forwardDelta(whole, lastAppliedSecond)
        if forward > 12 * 60 * 60 then return end
    end

    -- Read the live clock on EVERY pass and correct only real drift.
    --
    -- The projection standing still is not proof that the world agrees with
    -- it. This function used to return early whenever `whole` equalled the
    -- second it last wrote, which is always the case while the server clock
    -- is frozen (or `rate` is 0): the live clock was then never read again.
    -- Two things break that assumption, both measured 14 Sep on two clients
    -- joining a server frozen at 18:30:13. First, the joining client receives
    -- its first snapshot in the main menu and writes 18:30:13 into the menu
    -- world; the pristine save that loads next carries its own time of day
    -- and replaces the clock (one client came up near 09:40, the other near
    -- 22:15 -- one save each). Second, nothing native holds the clock
    -- (SetPausedState is deliberately not used, see below), so REDengine kept
    -- advancing both at its natural 8x. With the early return, neither
    -- client ever converged; each drifted from its own save for good.
    --
    -- SetGameTimeByHMS is still a time JUMP for the whole world: issued
    -- continuously it forces the streamer to re-resolve world nodes, which
    -- resurrects destroyed props (measured 25 Aug: instant prop restore with
    -- the 500 ms loop, delayed restore with the 5 s weather enforce). The
    -- read below is what keeps corrections rare: at the engine's natural rate
    -- the drift stays inside the tolerance and nothing is written. A frozen
    -- clock is the exception -- the engine advances 8 game seconds per real
    -- second against a projection that does not move, so it is re-asserted
    -- every tolerance/8 real seconds (15 s at the default 120 s). That is the
    -- price of `weather.time.freeze`, not a defect of the projection.
    local live = Open77.environment.getTime()
    if type(live) == "table" then
        local liveSeconds = (live.hour * 3600 + live.minute * 60 + live.second) % 86400
        local target = whole % 86400
        local forward = Clock.forwardDelta(target, liveSeconds)
        local backward = Clock.forwardDelta(liveSeconds, target)
        local drift = math.min(forward, backward)
        if drift <= (Config.timeDriftToleranceSeconds or 120) then
            lastAppliedSecond = whole
            return
        end
    elseif lastAppliedSecond ~= nil and whole == lastAppliedSecond then
        -- Unreadable live clock and this exact second already written once:
        -- there is nothing to compare against, and re-issuing the same jump
        -- blindly twice a second is the 25 Aug prop-resurrection loop.
        return
    end

    local hour, minute, second = Clock.toHms(whole)
    local ok, reason = Open77.environment.setTime(hour, minute, second)
    if ok then lastAppliedSecond = whole
    else print("[open77_weather] time apply failed: " .. tostring(reason)) end
end

-- Only the trusted Cordon resource may set this local projection; clients have
-- no mutation network event. Normal server weather snapshots continue updating
-- underneath it and resume immediately on release, resource stop or lease expiry.
exports("setMatchClock", function(value)
    if GetInvokingResource() ~= "open77_cordon" then return false, "wrong_owner" end
    if value == nil then
        matchClock = nil
        lastAppliedSecond = nil
        applyTime(true)
        return true
    end
    if type(value) ~= "table" or type(value.matchId) ~= "string" or #value.matchId > 64
        or type(value.secondsOfDay) ~= "number" or value.secondsOfDay ~= value.secondsOfDay
        or value.secondsOfDay < 0 or value.secondsOfDay >= 86400
        or type(value.rate) ~= "number" or value.rate ~= value.rate or value.rate < 0 or value.rate > 120 then
        return false, "invalid_clock"
    end
    local changed = matchClock == nil or matchClock.matchId ~= value.matchId
    matchClock = { matchId = value.matchId, secondsOfDay = value.secondsOfDay,
        rate = value.rate, anchorLocalMs = nowMs(), expiresAtMs = nowMs() + 15000 }
    if changed then lastAppliedSecond = nil end
    applyTime(changed)
    return true
end)

local function remainingTransitionSeconds(atMs)
    if state == nil then return 0 end
    return math.max(0, state.weatherTransitionEndLocalMs - (atMs or nowMs())) / 1000
end

local function applyWeather(force, transitionSeconds)
    if state == nil or (not force and lastWeatherRevision == state.weatherRevision) then return end
    local ok, appliedOrReason = Open77.environment.setWeather(
        state.weatherPreset,
        transitionSeconds ~= nil and transitionSeconds or remainingTransitionSeconds(),
        state.weatherPriority)
    if not ok then
        print("[open77_weather] weather apply failed: " .. tostring(appliedOrReason))
        return
    end
    lastWeatherRevision = state.weatherRevision
end

RegisterNetEvent(EVENT_SYNC, function(value, requestId)
    if not validSnapshot(value) then
        print("[open77_weather] invalid server snapshot rejected")
        return
    end
    -- A different scope is not a newer reading of the world this client is in:
    -- it IS another world, because the player moved routing bucket or the
    -- server created or retired an override. Adopt it whatever its revision
    -- says, then let the revision rule resume inside the new scope.
    local scopeChanged = state ~= nil and state.scope ~= value.scope
    if not scopeChanged then
        if state ~= nil and value.authorityEpoch < state.authorityEpoch then return end
        if state ~= nil and value.authorityEpoch == state.authorityEpoch and
           value.revision < state.revision then return end
    end

    local receivedAt = nowMs()
    local sentAt = requests[tonumber(requestId)]
    local compensation = 0
    if sentAt ~= nil then
        compensation = math.min(Config.maxLatencyCompensationMs, math.max(0, receivedAt - sentAt) / 2)
        requests[tonumber(requestId)] = nil
    end

    local previousRevision = state and state.revision or nil
    local previousWeatherRevision = state and state.weatherRevision or nil
    local previousEpoch = state and state.authorityEpoch or nil
    local seconds = value.secondsOfDay
    if not value.frozen then seconds = seconds + value.rate * compensation / 1000 end
    local transitionRemainingMs = math.max(
        0, value.weatherTransitionRemainingMs - compensation)
    state = {
        authorityEpoch = value.authorityEpoch,
        revision = value.revision,
        weatherRevision = value.weatherRevision,
        scope = value.scope,
        bucket = value.bucket,
        secondsOfDay = Clock.normalize(seconds),
        anchorLocalMs = receivedAt,
        rate = value.rate,
        frozen = value.frozen,
        weather = value.weather,
        weatherPreset = value.weatherPreset,
        weatherPriority = value.weatherPriority,
        transitionSeconds = value.transitionSeconds,
        weatherTransitionEndLocalMs = receivedAt + transitionRemainingMs,
        randomWeather = value.randomWeather == true,
        nextWeatherInMs = value.nextWeatherInMs,
        latencyCompensationMs = compensation,
        reason = value.reason,
    }

    -- The server clock is projected twice/second. Do not hold REDengine's
    -- SetPausedState here: runtime validation with two active clients proved
    -- that it also slows gameplay/physics in this session flow.
    Open77.environment.setWeatherFrozen(true)
    local authorityChanged = previousEpoch ~= nil and previousEpoch ~= state.authorityEpoch
    -- A scope change forces both halves. The clock because the new scope's time
    -- of day can be anywhere on the dial, including more than twelve hours ahead
    -- of the one being projected, which the rewind guard in applyTime would
    -- otherwise refuse; the weather because the new scope's weatherRevision is
    -- drawn from the same counter and can legitimately be lower than the one
    -- already applied.
    local revisionChanged = scopeChanged or authorityChanged or
        (previousRevision ~= nil and previousRevision ~= state.revision)
    local weatherChanged = scopeChanged or authorityChanged or previousWeatherRevision == nil or
        previousWeatherRevision ~= state.weatherRevision
    if scopeChanged then lastAppliedSecond = nil end
    applyTime(revisionChanged)
    applyWeather(weatherChanged, transitionRemainingMs / 1000)
    TriggerEvent("open77:weather:updated", state)
    if previousRevision == nil then
        local hour, minute, second = Clock.toHms(projectedSeconds())
        print(string.format(
            "[open77_weather] synchronized at %02d:%02d:%02d weather=%s rate=%.2fx rtt/2=%.1fms",
            hour, minute, second, state.weather, state.rate, compensation))
    elseif authorityChanged then
        print(string.format(
            "[open77_weather] authority epoch changed; accepted revision=%d epoch=%.0f",
            state.revision, state.authorityEpoch))
    elseif scopeChanged then
        local hour, minute, second = Clock.toHms(projectedSeconds())
        print(string.format(
            "[open77_weather] environment scope changed to %s at %02d:%02d:%02d weather=%s",
            state.scope, hour, minute, second, state.weather))
    elseif weatherChanged then
        print(string.format(
            "[open77_weather] weather synchronized preset=%s transitionRemaining=%.1fs revision=%d",
            state.weather, transitionRemainingMs / 1000, state.weatherRevision))
    end
end)

RegisterNetEvent("open77:command:result", function(raw, accepted, message)
    if type(raw) ~= "string" or string.match(string.lower(raw), "^weather") == nil then return end
    print(string.format("[server command] %s %s: %s",
        accepted and "OK" or "ERR", raw, tostring(message or "")))
end)

AddEventHandler("onClientResourceStart", function(name)
    if name == GetCurrentResourceName() then
        -- Recover a stale lock left by an older resource generation before the
        -- first authoritative snapshot arrives.
        Open77.environment.setTimeFrozen(false)
        requestSync()
    end
end)

AddEventHandler("onClientResourceStop", function(name)
    if name == "open77_cordon" and matchClock ~= nil then
        matchClock = nil
        lastAppliedSecond = nil
        applyTime(true)
    end
    if name ~= GetCurrentResourceName() then return end
    stopped = true
    -- Fail open if the authoritative resource is deliberately stopped: restore
    -- vanilla progression instead of leaving the player's world frozen.
    Open77.environment.setTimeFrozen(false)
    Open77.environment.setWeatherFrozen(false)
end)

CreateThread(function()
    while not stopped do
        Wait(Config.applyIntervalMs)
        applyTime(false)
    end
end)

CreateThread(function()
    while not stopped do
        Wait(Config.syncIntervalMs)
        requestSync()
    end
end)

CreateThread(function()
    while not stopped do
        Wait(Config.environmentEnforceIntervalMs)
        if state ~= nil then
            -- REDengine missions can rewrite the automatic-weather flag or
            -- submit another preset locally. Reclaim both after the shared
            -- transition is complete; repeating the already-active preset is
            -- a no-op in the native weather runtime.
            -- Act only on observed divergence. The unconditional forced
            -- re-apply every pass was NOT a native no-op: each submission
            -- re-evaluated world state and resurrected destroyed props
            -- (measured 25 Aug). A false frozen flag is the evidence that
            -- something local touched the weather; only then reclaim it.
            local frozen, reason = Open77.environment.isWeatherFrozen()
            if frozen ~= true then
                local ok, freezeReason = Open77.environment.setWeatherFrozen(true)
                if not ok then
                    print("[open77_weather] weather lock restore failed: " ..
                        tostring(freezeReason or reason))
                end
                if remainingTransitionSeconds() <= 0 then applyWeather(true, 0) end
            end
            -- Unforced retry: a no-op once one application succeeded for the
            -- current revision (lastWeatherRevision catches up), but keeps
            -- retrying while the initial apply failed (world not ready at
            -- sync receipt). Without this, one client can stay on its local
            -- weather forever (measured 25 Aug: rain on one client, clear on
            -- the other, same session).
            applyWeather(false)
        end
    end
end)

exports("isReady", function() return state ~= nil end)
exports("requestSync", requestSync)
exports("getState", function()
    if state == nil then return nil end
    local seconds = projectedSeconds()
    local hour, minute, second = Clock.toHms(seconds)
    return {
        revision = state.revision,
        weatherRevision = state.weatherRevision,
        authorityEpoch = state.authorityEpoch,
        scope = state.scope,
        bucket = state.bucket,
        secondsOfDay = seconds,
        hour = hour,
        minute = minute,
        second = second,
        rate = state.rate,
        frozen = state.frozen,
        weather = state.weather,
        weatherPreset = state.weatherPreset,
        weatherTransitionRemainingMs = math.floor(remainingTransitionSeconds() * 1000),
        randomWeather = state.randomWeather,
        nextWeatherInMs = state.nextWeatherInMs and
            math.max(0, state.nextWeatherInMs - (nowMs() - state.anchorLocalMs)) or nil,
        latencyCompensationMs = state.latencyCompensationMs,
    }
end)
