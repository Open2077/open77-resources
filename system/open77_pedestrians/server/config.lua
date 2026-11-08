local buckets = {}
for value in GetConvar("open77_pedestrians_buckets", "0"):gmatch("[^,]+") do
    local bucket = tonumber(value)
    if bucket and bucket % 1 == 0 then buckets[bucket] = true end
end

-- Lane classes of the walking crowd's catalogue a walker may use (1: maxSpeedRaw 1.0, 3-6 m wide;
-- 10: maxSpeedRaw 10.0, 2-3 m wide), a comma list.
local laneClasses = {}
for value in GetConvar("open77_pedestrians_lane_classes", "1,10"):gmatch("[^,]+") do
    local class = tonumber(value)
    if class and class % 1 == 0 then laneClasses[class] = true end
end

Open77PedestrianConfig = {
    enabled = GetConvarBool("open77_pedestrians_enabled", true),
    buckets = buckets,
    -- Whether a shot can kill a pedestrian (immortal ones take no damage), and whether shots and
    -- deaths make pedestrians flee and cower. Read once when the resource starts.
    mortal = GetConvarBool("open77_pedestrians_mortal", true),
    panic = GetConvarBool("open77_pedestrians_panic", true),
    -- Global ceiling (shared with the walking crowd under the server's NPC limit per resource, npcs.maximumPerResource)
    -- and, per player, how many may stand within the streaming radius of that player's client.
    maxActive = math.max(0, math.min(30000, GetConvarInt("open77_pedestrians_max_active", 8000))),
    maxNearPlayer = math.max(0, math.min(256, GetConvarInt("open77_pedestrians_max_near_player", 256))),
    -- Scan four times a second and spawn at most spawnsPerTick per scan in all, and at most
    -- spawnsPerPlayerTick a scan near any one player (16 a second): a client builds a handful of
    -- bodies at a time instead of a burst. A player entering the world used to get up to 64
    -- seated bodies a second (plus 64 walkers) and dropped to 1-3 fps for seconds. Pedestrians appear
    -- 120 m out, a client streams them from 140 m (+20 m before streaming out) and seated ones
    -- retire past 150 m: activate < streaming < retire <= streaming + hysteresis.
    tickMs = 250,
    activateRadiusM = 120,
    retireRadiusM = 150,
    verticalRangeM = 30,
    spawnsPerTick = 16,
    spawnsPerPlayerTick = math.max(1, math.min(64, GetConvarInt("open77_pedestrians_spawns_per_player_tick", 4))),
    -- Cells (64 m) of the players' windows the seated scan examines a pass, in rotation (scheduler.lua).
    seatedCellsPerPass = 160,
    streamingRadiusM = 140,
    streamingHysteresisM = 20,
    -- Cells and players one slice of the scan may examine (~18 Lua instructions each, ~560 k at most
    -- measured) before the rest waits for the next server tick: under the 1,000,000-instruction quota
    -- every coroutine of the resource shares in one server tick. With Open77.time.precise the slice
    -- ends at sliceMs first.
    scanWorkPerSlice = 30000,
    -- Time one resume of the passes may run (Open77.time.precise) before the rest waits for the next
    -- server tick: single ticks of this resource reached 40-50 ms of a 33 ms budget on the live
    -- server (2026-10-30, 78 players). The pass then runs across ticks, a few milliseconds each,
    -- and the loop starts the next one tickMs after this one started.
    sliceMs = 2,
    panicRadiusM = 15,
    -- Gunfire that hits nobody scares too, as the game's gunshot stimulus scares its crowd (a district's
    -- GunShotStimRange: 30 m in the city): every pedestrian within gunfireRadiusM of a player who fires
    -- (`open77:playerGunfire`, admitted firearm rounds) panics, running from the shooter. One volley per
    -- gunfireCellM cell of a bucket every gunfireRepeatS is enough: the next only finds the fleeing.
    gunfirePanic = GetConvarBool("open77_pedestrians_gunfire_panic", true),
    gunfireRadiusM = 30,
    gunfireCellM = 16,
    gunfireRepeatS = 2,
    -- A player who draws a weapon (onPlayerWeaponChanged; bare fists are no weapon) scares the walkers that pass
    -- within crowd.brandishRadiusM of it, as the game's crowd backs off from a drawn gun: they run in the traffic.
    brandishPanic = GetConvarBool("open77_pedestrians_brandish_panic", true),
    fleeDistanceMinM = 18,
    fleeDistanceM = 40,
    fleeFanDeg = 45,
    spotClearanceM = 0.5,
    fleeTimeoutMs = 20000,
    -- After its flee a pedestrian cowers where it stopped: one of these catalogue
    -- profiles (repeat a name to weight it) and a random clip of it, for a random
    -- cowerMinS..cowerMaxS, then walks back to its spot and sits again.
    panicProfiles = { "cower", "cower", "sitafraid" },
    cowerMinS = 60,
    cowerMaxS = 80,
    returnAcceptanceM = 1.5,
    returnTimeoutMs = 60000,
    returnAttempts = 2,
    -- A corpse leaves deadRetireS after death once no player stands within corpseQuietM, and after
    -- deadRetireMaxS in any case; a pedestrian out of walk-back attempts likewise after
    -- strandedRetireS / strandedRetireMaxS.
    deadRetireS = 60,
    deadRetireMaxS = 120,
    corpseQuietM = 25,
    strandedRetireS = 120,
    strandedRetireMaxS = 300,
    hitDamage = 50,
    spotCooldownS = 120,
    failureCooldownS = 30,
    fallbackSecondsOfDay = 43200,
    -- The walking crowd (crowd.lua): its own switch, its own ceiling (under the server's NPC limit
    -- per resource: up to crowdMaxActive walking beside maxActive seated) and, per player, how many walkers may stand
    -- within the streaming radius of that player's client.
    crowdEnabled = GetConvarBool("open77_pedestrians_crowd_enabled", true),
    crowdMaxActive = math.max(0, math.min(30000, GetConvarInt("open77_pedestrians_crowd_max_active", 16000))),
    -- A zone cluster (players chained within crowd.clusterLinkM) holds at most this many walkers, however many players
    -- stand in it: crowdMaxNearPlayer for the first, crowd.clusterPerPlayer * sqrt(n - 1) more for n players.
    crowdMaxCluster = math.max(0, math.min(4000, GetConvarInt("open77_pedestrians_crowd_max_cluster", 600))),
    crowdMaxNearPlayer = math.max(0, math.min(256, GetConvarInt("open77_pedestrians_crowd_max_near_player", 200))),
    -- The vanilla crowd's density (crowdsets-generated.lua): around each player the walkers number what the game
    -- keeps on the lane fragments within crowd.densityRadiusM for the hour, times this factor (0: none, 1: the
    -- game's own count), capped by crowdMaxNearPlayer. An average street at noon wants ~18 within 90 m, Corpo
    -- Plaza ~96, and the night about a third fewer.
    crowdDensity = math.max(0, math.min(10, tonumber(GetConvar("open77_pedestrians_crowd_density", "8")) or 8)),
    laneClasses = laneClasses,
    -- The crowd also reads tickMs, scanWorkPerSlice, panicRadiusM, fleeTimeoutMs, hitDamage, deadRetire*
    -- and corpseQuietM above, and mortal / panic. Walkers appear spawnMinM..spawnMaxM from a player on
    -- a lane with crowd fragments, stream from 140 m and retire past 150 m (as the seated ones do).
    -- They are hosted: native AI on the client the platform elects for each (balanced over the
    -- nearby clients), which puts the walker into the game's own pedestrian traffic where it spawned:
    -- the native mover keeps it on the game's lanes and at its lights, the other clients replay the
    -- host's motion. Fully native: a walker in the game's traffic takes no AI command, so its panic is
    -- the game's own crowd fear in the traffic (it runs from the threat point for fleeTimeoutMs, then
    -- calms) and its benches are the game's own workspot visits, replayed on every client by the
    -- server's sit on the crowd-catalogue spot under the body.
    crowd = {
        spawnMinM = 22,
        spawnMaxM = 65,
        verticalRangeM = 30,
        retireRadiusM = 150,
        streamingRadiusM = 140,
        streamingHysteresisM = 20,
        spawnsPerTick = 16,
        -- At most this many new walkers a tick around any one player (16 a second): the crowd of a
        -- player entering the world fills in over seconds instead of arriving at once.
        spawnsPerPlayerTick = math.max(1, math.min(64, GetConvarInt("open77_pedestrians_crowd_spawns_per_player_tick", 4))),
        candidateTries = 6,
        separationM = 3,
        -- A visit the catalogue has no free spot for (none under the body, or it is held or resting)
        -- sends the walker on with workspot visits refused for visitRetryS.
        visitRetryS = 60,
        -- On a catalogue spot it sits spotStayMinS..spotStayMaxS, then walks on with visits refused for
        -- visitRetryS; the spot itself is free at once. spotCooldownS is the least time a corpse's spot rests.
        spotStayMinS = 20,
        spotStayMaxS = 60,
        spotCooldownS = 60,
        -- A native body can get stuck: a walker in the traffic that has not moved stuckM in stuckS
        -- leaves. The game's walkers wait at red lights up to ~38 s (measured), so stuckS is well past.
        stuckS = 60,
        stuckM = 1.5,
        -- Density (with crowdsets-generated.lua): a player wants the game's count of walkers within densityRadiusM
        -- (the spawn ring's outer edge), worked out again when it has moved densityRefreshM or after densityRefreshS.
        -- When the hour or a move leaves too many around, the walkers past spawnMaxM of every living player go first,
        -- at most overflowRetiresPerTick a tick, while each player streaming them holds more than overflowFactor times
        -- its count plus overflowSlack.
        densityRadiusM = 65,
        densityRefreshM = 16,
        densityRefreshS = 10,
        overflowFactor = 1.0,
        overflowSlack = 2,
        overflowRetiresPerTick = 4,
        -- A walking player gets new walkers behind it rather than in front: within aheadM, a candidate less than
        -- aheadCos off its direction of travel (over the last second) is refused, so they do not pop up in view.
        aheadM = 45,
        aheadCos = 0.3,
        brandishRadiusM = 6,
        -- Zone clusters: players within clusterLinkM of each other (chained) share one crowd; each extra player adds
        -- clusterPerPlayer * sqrt(n - 1) to the cluster's cap (crowdMaxCluster above).
        clusterLinkM = 100,
        clusterPerPlayer = 40,
    },
}
