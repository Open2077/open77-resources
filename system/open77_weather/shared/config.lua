-- open77_weather public configuration.
--
-- This file is downloaded by clients, so never put secrets or ACL data here.
-- Durations below are real-world seconds; `timeScale` controls how many game
-- seconds pass per real second.

Open77WeatherConfig = {
    -- 3: snapshots carry a `scope` (`default`, or `bucket:<n>`), and the carried
    -- reload state is a default scope plus an array of per-bucket overrides.
    -- Both shapes changed, so a snapshot written by the previous generation is
    -- refused rather than half-adopted -- see `restoreState` in server/main.lua.
    protocol = 3,

    -- Every dedicated-server boot starts at exactly noon.
    startupTime = { hour = 12, minute = 0, second = 0 },
    -- MUST match the engine's natural clock rate (vanilla: 8 game seconds per
    -- real second, one day per three real hours). The shared clock then stays
    -- aligned without corrections; every correction is a SetGameTimeByHMS
    -- world time-jump that resurrects destroyed props (measured 25 Aug: at
    -- 4.0 the 4 s/s structural drift forced a jump — and a prop wave — every
    -- ~30 s). Changing day length requires a native rate control, not this.
    timeScale = 8.0,
    timeFrozen = false,

    -- Clients request a fresh timestamp periodically. The RTT/2 of that request
    -- is added to the received clock, bounded by maxLatencyCompensationMs.
    syncIntervalMs = 15000,
    applyIntervalMs = 500,
    -- Only correct the clock when it has really drifted: every SetGameTimeByHMS
    -- is a world-state time jump, and issuing them continuously makes the
    -- streamer re-resolve nodes and resurrect destroyed props (measured 25 Aug).
    -- The live clock is compared on every apply pass, so this is also the
    -- cadence of a frozen clock: the engine keeps advancing at 8 s/s under a
    -- frozen projection and is pulled back every tolerance/8 real seconds
    -- (15 s here). Raising it makes those jumps rarer but larger.
    timeDriftToleranceSeconds = 120,
    maxLatencyCompensationMs = 2000,
    minimumRequestIntervalMs = 1000,

    -- The server also broadcasts a fresh authoritative snapshot even when the
    -- state did not change. Stable weather is reasserted client-side after its
    -- transition completes so a quest or vanilla controller cannot leave one
    -- player on a different preset.
    heartbeatIntervalMs = 5000,
    environmentEnforceIntervalMs = 5000,

    weatherPriority = 5,
    initialWeather = "sunny",
    randomWeather = true,
    initialWeatherDurationSeconds = 180,
    weatherSchedulerIntervalMs = 1000,

    -- `name` is the stable API/command name; `preset` is the REDengine value.
    -- Weights are relative. A duration is selected after the preset starts.
    presets = {
        { name = "sunny",       preset = "24h_weather_sunny",        weight = 28, minSeconds = 480, maxSeconds = 900, transitionSeconds = 18 },
        { name = "lightclouds", preset = "24h_weather_light_clouds", weight = 24, minSeconds = 360, maxSeconds = 720, transitionSeconds = 20 },
        { name = "cloudy",      preset = "24h_weather_cloudy",       weight = 18, minSeconds = 300, maxSeconds = 600, transitionSeconds = 24 },
        { name = "rain",        preset = "24h_weather_rain",         weight = 12, minSeconds = 180, maxSeconds = 420, transitionSeconds = 30 },
        { name = "heavyclouds", preset = "24h_weather_heavy_clouds", weight = 8,  minSeconds = 240, maxSeconds = 480, transitionSeconds = 26 },
        { name = "fog",         preset = "24h_weather_fog",          weight = 5,  minSeconds = 180, maxSeconds = 360, transitionSeconds = 28 },
        { name = "pollution",   preset = "24h_weather_pollution",    weight = 3,  minSeconds = 180, maxSeconds = 360, transitionSeconds = 28 },
        { name = "sandstorm",   preset = "24h_weather_sandstorm",    weight = 2,  minSeconds = 120, maxSeconds = 300, transitionSeconds = 35 },
    },

    aliases = {
        clear = "sunny",
        clouds = "cloudy",
        light_clouds = "lightclouds",
        heavy_clouds = "heavyclouds",
        storm = "sandstorm",
    },
}
