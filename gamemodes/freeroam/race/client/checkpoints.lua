-- One durable, personal checkpoint. Never predict acceptance from local distance:
-- the server's nextCheckpoint is the sole source for this zone and the GPS blip.
-- Foot races use landing cylinders and arrows; vehicles use raised chevrons.
-- All markers are personal visuals; the server alone accepts crossings.
RaceCheckpointVisual = {}
local handle, beacon, signature, marker
local retryAt = 0

function RaceCheckpointVisual.clear()
    if handle ~= nil then Open77.markers.remove(handle) end
    if beacon ~= nil then Open77.markers.remove(beacon) end
    handle, beacon, signature, marker = nil, nil, nil, nil
    retryAt = 0
end

function RaceCheckpointVisual.sync(state)
    local point = state and state.nextCheckpoint
    local phase = state and state.phase
    if RaceConfig.visuals.enabled == false or not state or state.participant ~= true or
        (phase ~= "grid" and phase ~= "countdown" and phase ~= "active") or
        type(point) ~= "table" or type(point.position) ~= "table" then
        RaceCheckpointVisual.clear()
        return
    end
    local radius = tonumber(point.radius) or RaceConfig.engine.checkpointRadius
    local visual = RaceConfig.visuals.checkpointMarker or {}
    local finish = tonumber(point.index) == tonumber(state.totalCheckpoints) and
        tonumber(state.lap) == tonumber(state.laps)
    local position = point.position
    local useMarker = state.onFoot == true
    if handle ~= nil and marker ~= useMarker then RaceCheckpointVisual.clear() end
    local api = Open77.markers
    local key = table.concat({ tostring(state.heatId), tostring(state.lap), tostring(point.id),
        tostring(point.index), tostring(finish), tostring(radius), tostring(useMarker),
        tostring(position.x), tostring(position.y), tostring(position.z),
        tostring(point.heading) }, ":")
    if signature == key then
        local snapshot = handle and Open77.markers.get(handle)
        local arrow = beacon and Open77.markers.get(beacon)
        if snapshot and not snapshot.failed and (not useMarker or (arrow and not arrow.failed)) then return end
        Open77.log.warn("Race checkpoint chevron lost: " ..
            tostring(snapshot and snapshot.error or "marker_not_found"))
        RaceCheckpointVisual.clear()
        retryAt = Open77.time.monotonic() + 2.0
    end
    if Open77.time.monotonic() < retryAt then return end
    local options = {
        position = { x = position.x, y = position.y,
            z = position.z + (tonumber(visual.lift) or 3.0) },
        shape = "chevron",
        radius = tonumber(visual.radius) or 2.5,
        height = tonumber(visual.height) or 3.5,
        rotation = { x = 0, y = 0, z = tonumber(point.heading) or 0 },
        color = finish and { r = 240, g = 243, b = 246, a = 220 } or
            { r = 34, g = 216, b = 226, a = 220 },
        maxDistance = RaceConfig.visuals.checkpointViewDistance or 180.0,
    }
    local beaconOptions
    if useMarker then
        local definitions = RaceFootMarkers.definitions(position, radius, finish,
            RaceConfig.visuals.checkpointViewDistance or 180.0)
        options, beaconOptions = definitions[1], definitions[2]
    end
    local ok, reason
    if handle ~= nil then
        ok, reason = Open77.markers.update(handle, options)
        if not ok then
            -- A lost native handle must not retain an obsolete destination.
            Open77.markers.remove(handle)
            handle, signature = nil, nil
        end
    else
        handle, reason = Open77.markers.create(options)
        marker = useMarker
        ok = handle ~= nil
    end
    if ok and useMarker then
        if beacon ~= nil then
            ok, reason = api.update(beacon, beaconOptions)
        else
            beacon, reason = api.create(beaconOptions)
            ok = beacon ~= nil
        end
    end
    if ok then
        signature = key
        Open77.log.info(("Race checkpoint chevron target=%s lap=%s acceptanceRadius=%.1f finish=%s"):format(
            tostring(point.index), tostring(state.lap), radius, tostring(finish)))
    else
        -- Treat both meshes as one target: never leave a stale arrow visible
        -- when a retarget or asynchronous handle replacement fails.
        RaceCheckpointVisual.clear()
        retryAt = Open77.time.monotonic() + 1.0
        Open77.log.warn("Race checkpoint chevron unavailable: " .. tostring(reason))
    end
end
