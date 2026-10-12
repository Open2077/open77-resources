-- The generator settings of open77_traffic, declared once here and read by
-- both halves: `server.lua` hands this table to `Open77.tunables.declare`, and
-- the in-game client panel reads these declarations directly.
--
-- These are DEFAULTS, not the live configuration. The host owns the values, so
-- an operator's change from the panel, from Warden or from the console
-- (`tunable.set open77_traffic <key> <value>`) is validated against the bounds
-- below, stored and persisted to `server/tunables.json`: it survives a reload,
-- a stop and a server restart, and it comes back with its stored value even if
-- the key leaves this declaration and rejoins it later. `tunable.reset
-- open77_traffic <key>` is what forgets an override. The panel's Reset button
-- is not a settings reset: it clears the fleet, and the one setting it does
-- write is `enabled = true`, because a reset is meant to resume spawning.
--
-- `enabled` is overwritten by server.lua before the declaration: false unless
-- the server profile sets the convar `open77_traffic_enabled`.
--
-- Every bound is a safety bound rather than a taste bound:
--   * `min` on a distance is the point below which a spawn gate stops being
--     conservative (the create-point exclusion in particular never drops below
--     20 m, whatever `minimumSpawnSeparation` says), and `min` on a cadence or
--     a limit is the point below which the controller would spin or admit
--     nothing at all;
--   * `max` on a fleet budget is this resource's own documented admission
--     budget -- the server's driving service caps independent of it -- and
--     `max` on `playerAreaRadius` is what bounds the span-cell sweep it
--     drives each spawn pass.
-- `step` is presentation only: the host never enforces it.
--
-- Two relations between keys cannot be expressed as per-key bounds, because a
-- candidate has to be inside the spawn band around its player and inside that
-- player's area:
--   minimumPlayerSpawnDistance <= groundProbeRadius
--   playerAreaRadius > minimumPlayerSpawnDistance
-- The server refuses either pair from the panel (naming it) and logs a warning
-- when an external write makes it hold. `minimumSpawnSeparation` has no such
-- relation to the probe radius: it is a distance between two cars, so a
-- separation wider than the band is a legitimate way to admit fewer cars.

TrafficSettings = {
    -- Density: how many cars may exist, and where around each player they are
    -- filled -- by the game's authored crowd density per lane
    -- (docs/research/traffic-native-spawning-design.md). The keys of the
    -- removed anchor generator's per-area limit (`carsPerArea`, `areaRadius`)
    -- are not reused, so a stored override of them cannot return with a new
    -- meaning.
    enabled = {
        value = false,
        type = "boolean",
        apply = "live",
        order = 1,
        label = "Traffic generation",
        description = "Off stops new cars from spawning. Cars already on the road keep driving until they are removed.",
        group = "Density",
    },
    carsGlobal = {
        value = 20000,
        type = "integer",
        min = 0,
        max = 20000,
        step = 1,
        unit = "cars",
        apply = "live",
        order = 2,
        label = "Max cars (server)",
        description = "Hard limit on this resource's cars across the whole server. Each car still needs a free simulator slot, so fewer may be on the road. 0 spawns none.",
        group = "Density",
    },
    maxCarsPerArea = {
        value = 60,
        type = "integer",
        min = 1,
        max = 1000,
        step = 1,
        unit = "cars",
        apply = "live",
        order = 3,
        label = "Max cars per area",
        description = "No car spawns in a player's area that already holds this many.",
        group = "Density",
    },
    playerAreaRadius = {
        value = 250,
        type = "number",
        min = 50,
        max = 350,
        step = 10,
        unit = "m",
        apply = "live",
        order = 4,
        label = "Area size",
        description = "Radius of the area around each player whose density is filled. It grows by a fifth and moves ahead at speed. Must stay above the min spawn distance; cars still only spawn inside the spawn distances.",
        group = "Density",
    },
    densityScale = {
        value = 1,
        type = "number",
        min = 0,
        max = 10,
        step = 0.1,
        apply = "live",
        order = 5,
        label = "Density scale",
        description = "Multiplies the game's density. 1 is the authored density; 0 spawns none.",
        group = "Density",
    },
    densityFloor = {
        value = 0,
        type = "number",
        min = 0,
        max = 1,
        step = 0.01,
        apply = "live",
        order = 6,
        label = "Density floor on foot",
        description = "Lowest density coefficient a road gets while the player is on foot. 0 keeps the authored values.",
        group = "Density",
    },
    densityFloorDriving = {
        value = 0,
        type = "number",
        min = 0,
        max = 1,
        step = 0.01,
        apply = "live",
        order = 7,
        label = "Density floor driving",
        description = "Lowest density coefficient a road gets while the player is in a vehicle. 0 keeps the authored values.",
        group = "Density",
    },
    timePeriod = {
        value = 0,
        type = "integer",
        min = 0,
        max = 3,
        step = 1,
        apply = "live",
        order = 8,
        label = "Time period",
        description = "Which of the game's four authored density periods to use. The server has no time of day yet.",
        group = "Density",
    },
    retireDistance = {
        value = 250,
        type = "number",
        min = 100,
        max = 425,
        step = 10,
        unit = "m",
        apply = "live",
        order = 9,
        label = "Removal distance",
        description = "Cleanup distance. Removal also waits until nobody has the car streamed and a 10 s absence has elapsed, except for a timed-out car no player is near enough to run and a car left behind a fast driver. 425 m is the streaming edge.",
        group = "Density",
    },

    -- Spawning: where a car may appear, and how hard the controller looks.
    spawnEveryMs = {
        value = 10,
        type = "integer",
        min = 10,
        max = 60000,
        step = 10,
        unit = "ms",
        apply = "live",
        order = 1,
        label = "Spawn interval",
        description = "Pause between two spawn attempts. Lower fills the streets faster.",
        group = "Spawning",
    },
    groundProbeRadius = {
        value = 180,
        type = "number",
        min = 20,
        max = 500,
        step = 5,
        unit = "m",
        apply = "live",
        order = 2,
        label = "Max spawn distance",
        description = "Farthest a new car can appear from a player. Past 350 m no player runs it, so it is removed.",
        group = "Spawning",
    },
    minimumPlayerSpawnDistance = {
        value = 60,
        type = "number",
        min = 0,
        max = 500,
        step = 1,
        unit = "m",
        apply = "live",
        order = 3,
        label = "Min spawn distance",
        description = "Closest a new car can appear to a player. Must stay below the max spawn distance.",
        group = "Spawning",
    },
    minimumSpawnSeparation = {
        value = 5,
        type = "number",
        min = 5,
        max = 200,
        step = 1,
        unit = "m",
        apply = "live",
        order = 4,
        label = "Gap between cars",
        description = "Minimum space between a new car and other cars. At least 20 m is always kept.",
        group = "Spawning",
    },
    spawnLiftMetres = {
        value = 0.35,
        type = "number",
        min = 0,
        max = 20,
        step = 0.05,
        unit = "m",
        apply = "live",
        order = 5,
        label = "Spawn height",
        description = "How far above the road a new car is dropped, so it clears the kerb.",
        group = "Spawning",
    },
    launchSpeed = {
        value = 10,
        type = "number",
        min = 0,
        max = 25,
        step = 1,
        unit = "m/s",
        apply = "live",
        order = 6,
        label = "Spawn speed",
        description = "Speed a new car already has when its first player takes it over, along its lane. Lowered automatically when another car is close ahead. 0 spawns cars standing still.",
        group = "Spawning",
    },
    clearanceAttempts = {
        value = 3,
        type = "integer",
        min = 1,
        max = 10,
        step = 1,
        unit = "tries",
        apply = "live",
        order = 7,
        label = "Spawn retries",
        description = "Other spots tried in one attempt when the best spot is blocked.",
        group = "Spawning",
    },
    groundFailureLimit = {
        value = 2,
        type = "integer",
        min = 1,
        max = 100,
        step = 1,
        unit = "misses",
        apply = "live",
        order = 8,
        label = "Bad spot limit",
        description = "Failed ground checks in a row before a spawn spot is skipped for five minutes.",
        group = "Spawning",
    },

    -- Timeouts: how a car that cannot run is noticed and released. Both floors
    -- are 10 s because of platform timing: the server holds a car's previous
    -- simulator off for 8 s after its lease expires, so a shorter orphan window
    -- deletes cars that were about to recover, and a new car needs ~5-6 s
    -- before its first owner sample arrives.
    orphanSeconds = {
        value = 10,
        type = "integer",
        min = 10,
        max = 3600,
        step = 1,
        unit = "s",
        apply = "live",
        order = 1,
        label = "Abandoned car timeout",
        description = "Requests cleanup after the car loses its simulator for this long. The car and driver stay while observed and can recover, unless no player is near enough to run it; otherwise removal requires continuous absence.",
        group = "Timeouts",
    },
    neverOwnedSeconds = {
        value = 10,
        type = "integer",
        min = 10,
        max = 3600,
        step = 1,
        unit = "s",
        apply = "live",
        order = 2,
        label = "Unclaimed car timeout",
        description = "Requests cleanup if no simulator takes the new car within this time. An observed car and its driver stay until nobody can see them, unless no player is near enough to run it.",
        group = "Timeouts",
    },
    timeoutMilliseconds = {
        value = 3600000,
        type = "integer",
        min = 1000,
        max = 3600000,
        step = 1000,
        unit = "ms",
        apply = "live",
        order = 3,
        label = "Max car lifetime",
        description = "Maximum driving task duration. Once it ends, the car and driver remain while observed, then cleanup frees their place in the fleet.",
        group = "Timeouts",
    },

    -- Reactions: which other server resources may make these cars panic.
    -- The driving service refuses every command for a car from any resource
    -- but the one that drives it, so this list is this resource's explicit
    -- approval of named callers of its `panic` export. It is a tunable rather
    -- than a convar because any resource may override a convar at runtime.
    panicResources = {
        value = "",
        type = "text",
        apply = "live",
        order = 1,
        label = "Panic callers",
        description = "Server resources allowed to call this resource's panic export, by exact name, separated by + (at most 32 characters in the panel). Empty or none allows no other resource; the panel's own Panic button is unaffected.",
        group = "Reactions",
    },

    -- Players: what a player may do to these drivers and cars. Both default to
    -- on and both reach the cars and drivers already in the world, not only
    -- the next spawn.
    driversKillable = {
        value = true,
        type = "boolean",
        apply = "live",
        order = 1,
        label = "Killable drivers",
        description = "Off makes every driver unkillable: player hits no longer hurt them. Living drivers change at once; drivers already killed stay dead.",
        group = "Players",
    },
    carsStealable = {
        value = true,
        type = "boolean",
        apply = "live",
        order = 2,
        label = "Stealable cars",
        description = "Off locks every car this resource made, including released and stolen ones, for everyone: no seat can be entered and no door action opens it, so a killed driver stays at the wheel. On unlocks them.",
        group = "Players",
    },
    driverDamageScale = {
        value = 1.0, type = "number", min = 0.01, max = 10, step = 0.05, apply = "live",
        order = 3, label = "Driver damage scale", group = "Players",
        description = "Scales server class prices, not native damage. Perks, native headshots and instant-kill flags do not multiply driver damage.",
    },
    driverHitsPerSecond = {
        value = 16, type = "integer", min = 1, max = 16, step = 1, apply = "live",
        order = 4, label = "Driver hit budget", group = "Players",
        description = "Player-wide contact observations per second, with one second of burst. Folded hits spend their full count; melee is additionally capped at ten.",
    },
    driverDamagePerSecond = {
        value = 220, type = "number", min = 1, max = 1000, step = 10, apply = "live",
        order = 5, label = "Driver damage budget", group = "Players",
        description = "Player-wide server-priced HP per second with one second of burst, shared across drivers. Must cover at least one scaled class price for that class to hurt drivers.",
    },
}
