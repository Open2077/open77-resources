-- Bounded admission cache for complete, recoverable Race display states.
-- Explicit refreshes bypass deduplication. Gameplay events never use this path.
RaceStateDelivery = {}

function RaceStateDelivery.new(options)
    local entries, streams = {}, {}
    local count, bytes = 0, 0
    local maxEntries, maxBytes = options.maxEntries or 512, options.maxBytes or 8 * 1024 * 1024
    local ordinaryLimit = options.ordinaryLimit or 46000
    local maxStreams = options.maxStreams or 16 -- the runtime's per-resource cap
    local delivery = {}

    local function forgetCached(player)
        local previous = entries[player]
        if previous then
            bytes, count = bytes - #previous, count - 1
            entries[player] = nil
        end
    end

    local function pending(player)
        local samePlayer, active = false, 0
        for stream, owner in pairs(streams) do
            local status = options.latentStatus(stream)
            -- The runtime retains all active streams; nil means no longer
            -- active (finished history may already have been pruned).
            if status and status.state == "sending" then
                active = active + 1
                samePlayer = samePlayer or owner == player
            else streams[stream] = nil end
        end
        return samePlayer, active
    end

    function delivery.send(player, payload, encoded, force)
        local inFlight, active = pending(player)
        if #encoded > ordinaryLimit then
            forgetCached(player)
            if active >= maxStreams then return false, "stream_limit" end
            local stream, reason = options.sendLatent(player, payload)
            if not stream then return false, reason end
            streams[stream] = player
            return true
        end
        -- An earlier large state can finish after this small state. Until all
        -- its streams drain, keep ordinary refreshes eligible and uncached.
        if not force and not inFlight and entries[player] == encoded then
            return true, "unchanged"
        end
        local admitted, reason = options.send(player, payload)
        if admitted ~= true then return false, reason end
        forgetCached(player)
        if not inFlight and #encoded <= maxBytes and count < maxEntries and bytes + #encoded <= maxBytes then
            entries[player] = encoded
            count, bytes = count + 1, bytes + #encoded
        end
        return true
    end

    function delivery.hasPending(player)
        local inFlight = pending(player)
        return inFlight
    end

    function delivery.forget(player)
        forgetCached(player)
        for stream, owner in pairs(streams) do if owner == player then streams[stream] = nil end end
    end
    function delivery.clear()
        entries, streams, count, bytes = {}, {}, 0, 0
    end
    function delivery.inspect()
        local active = 0
        for _ in pairs(streams) do active = active + 1 end
        return { entries = count, bytes = bytes, streams = active }
    end
    return delivery
end
