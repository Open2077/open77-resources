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
    -- Global ceiling (the platform allows 1024 NPCs per resource, shared with the walking crowd)
    -- and, per player, how many may stand within the streaming radius of that player's client.
    maxActive = math.max(0, math.min(512, GetConvarInt("open77_pedestrians_max_active", 512))),
    maxNearPlayer = math.max(0, math.min(256, GetConvarInt("open77_pedestrians_max_near_player", 128))),
    -- Scan four times a second and spawn at most four per scan (16 a second) in small batches,
    -- each client builds a handful of bodies per frame instead of a burst. Pedestrians appear
    -- 120 m out, a client streams them from 140 m (+20 m before streaming out) and seated ones
    -- retire past 150 m: activate < streaming < retire <= streaming + hysteresis.
    tickMs = 250,
    activateRadiusM = 120,
    retireRadiusM = 150,
    verticalRangeM = 30,
    spawnsPerTick = 4,
    streamingRadiusM = 140,
    streamingHysteresisM = 20,
    -- Cells and players one slice of the scan may examine (~18 Lua instructions each, ~560 k at most
    -- measured) before the rest waits for the next server tick: under the 1,000,000-instruction quota
    -- every coroutine of the resource shares in one server tick.
    scanWorkPerSlice = 30000,
    panicRadiusM = 15,
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
    -- The walking crowd (crowd.lua): its own switch, its own ceiling (the platform allows 1024 NPCs
    -- per resource: up to 512 seated and 512 walking) and, per player, how many walkers may stand
    -- within the streaming radius of that player's client.
    crowdEnabled = GetConvarBool("open77_pedestrians_crowd_enabled", true),
    crowdMaxActive = math.max(0, math.min(512, GetConvarInt("open77_pedestrians_crowd_max_active", 512))),
    crowdMaxNearPlayer = math.max(0, math.min(64, GetConvarInt("open77_pedestrians_crowd_max_near_player", 24))),
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
        spawnMinM = 35,
        spawnMaxM = 90,
        verticalRangeM = 30,
        retireRadiusM = 150,
        streamingRadiusM = 140,
        streamingHysteresisM = 20,
        spawnsPerTick = 4,
        candidateTries = 6,
        separationM = 3,
        -- A visit the catalogue has no free spot for (none under the body, or it is held or resting)
        -- sends the walker on with workspot visits refused for visitRetryS.
        visitRetryS = 60,
        -- On a catalogue spot it sits spotStayMinS..spotStayMaxS, and the spot rests spotCooldownS after.
        spotStayMinS = 20,
        spotStayMaxS = 60,
        spotCooldownS = 60,
        -- A native body can get stuck: a walker in the traffic that has not moved stuckM in stuckS
        -- leaves. The game's walkers wait at red lights up to ~38 s (measured), so stuckS is well past.
        stuckS = 60,
        stuckM = 1.5,
    },
}
