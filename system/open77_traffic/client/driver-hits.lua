-- Traffic forwards counted contact observations, never native health prices.
-- Public open77:npcDamage remains independent; forwarding it would double count.
-- Bounds are per PLAYER, not target: 128 observations queued, 16 hits/second
-- (one second of burst), at most 16 rows/hits in one packet per 100 ms.
local pending, pendingCount = {}, 0
local MAX_PENDING, MAX_AGE, MAX_HITS = 128, 30, 16
local generation, stopped = nil, false
local sequence, retrySequence, nextSend, nextSummary = 0, nil, 0, 0
local tokens, tokenAt = MAX_HITS, 0
local counts = { overflow = 0, stale = 0, reset = 0, backpressure = 0, invalid = 0 }

local function reset()
    counts.reset = counts.reset + pendingCount
    pending, pendingCount, retrySequence = {}, 0, nil
    nextSend, tokens, tokenAt = 0, MAX_HITS, Open77.time.monotonic()
end

local function session()
    local net = Open77.network.status()
    local current = net and net.phase == "active" and tostring(net.generation) or nil
    if current ~= generation then reset(); generation = current end
    return current
end

local function finite(n)
    return type(n) == "number" and n == n and math.abs(n) < math.huge
end

AddEventHandler("open77_traffic:driverDamageClaim", function(npcId, observations, weapon, attackKind, incarnation, age, claimGeneration)
    local count = math.tointeger(tonumber(observations))
    if not count or count < 1 or count > MAX_HITS then counts.invalid = counts.invalid + 1; return end
    local current = session()
    if stopped or not current or tostring(claimGeneration) ~= current then
        counts.reset = counts.reset + count
        return
    end
    local npc, kind, elapsed = math.tointeger(tonumber(npcId)), math.tointeger(tonumber(attackKind)), tonumber(age)
    if not npc or npc <= 0 or not kind or kind < 1 or kind > 3 or not tonumber(weapon)
        or type(incarnation) ~= "string" or incarnation == "" or not finite(elapsed) or elapsed < 0 then
        counts.invalid = counts.invalid + count; return
    end
    if elapsed > MAX_AGE then counts.stale = counts.stale + count; return end
    if pendingCount + count > MAX_PENDING then counts.overflow = counts.overflow + count; return end
    local at = Open77.time.monotonic() - elapsed
    pendingCount = pendingCount + count
    for _, row in ipairs(pending) do
        if row.npc == npc and row.body == incarnation and row.weapon == weapon and row.kind == kind then
            row.count = row.count + count
            row.at = math.min(row.at, at)
            return
        end
    end
    pending[#pending + 1] = { npc = npc, count = count, weapon = weapon, kind = kind, body = incarnation, at = at }
end)

CreateThread(function()
    while not stopped do
        Wait(100)
        local now = Open77.time.monotonic()
        if session() and now >= nextSend then
            nextSend = now + 0.1 -- no catch-up packet burst after a stall
            tokens = math.min(MAX_HITS, tokens + math.max(0, now - tokenAt) * MAX_HITS)
            tokenAt = now
            for index = #pending, 1, -1 do
                local row = pending[index]
                if now - row.at > MAX_AGE then
                    counts.stale = counts.stale + row.count
                    pendingCount = pendingCount - row.count
                    table.remove(pending, index)
                end
            end
            local available = math.floor(tokens + 1e-9)
            if pending[1] and available > 0 then
                local batch, sentCount = {}, 0
                for _, row in ipairs(pending) do
                    local count = math.min(row.count, available - sentCount)
                    batch[#batch + 1] = { npc = row.npc, count = count, weapon = row.weapon, kind = row.kind, age = now - row.at }
                    sentCount = sentCount + count
                    if sentCount == available or #batch == MAX_HITS then break end
                end
                -- A failed enqueue consumes neither count nor budget nor identity.
                if not retrySequence then
                    sequence = math.max(sequence + 1, math.floor(now * 1000000))
                    retrySequence = sequence
                end
                if TriggerServerEvent("open77_traffic:driverDamage", batch, retrySequence) == true then
                    tokens = math.max(0, tokens - sentCount)
                    pendingCount = pendingCount - sentCount
                    for _, row in ipairs(batch) do
                        pending[1].count = pending[1].count - row.count
                        if pending[1].count == 0 then table.remove(pending, 1) end
                    end
                    retrySequence = nil
                else
                    counts.backpressure = counts.backpressure + 1
                end
            end
        end
        if now >= nextSummary then
            nextSummary = now + 10
            local rows = {}
            for reason, count in pairs(counts) do
                if count > 0 then rows[#rows + 1] = reason .. "=" .. count; counts[reason] = 0 end
            end
            if #rows > 0 then table.sort(rows); print("[traffic] driver damage: " .. table.concat(rows, " ")) end
        end
    end
end)

AddEventHandler("open77:worldReady", reset)
AddEventHandler("onClientResourceStop", function(name)
    if name == GetCurrentResourceName() then stopped = true; reset() end
end)
