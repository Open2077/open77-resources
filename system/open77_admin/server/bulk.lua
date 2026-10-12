-- Explicit, ACL-checked server-wide actions. Snapshot once; recheck before each
-- mutation. A single worker prevents overlapping TP/cleanup batches.
local Config = Admin.Config.bulk
local active, nextRunAt = nil, 0
local sessions = {}
AddEventHandler("onPlayerDisconnected", function(id)
    id = tonumber(id)
    if not id then return end
    sessions[id] = nil
    if active and active.actor == id then active.cancelled = "operator disconnected" end
end)

local function session(id)
    if not Open77.players.name(id) then return nil end
    if not sessions[id] then sessions[id] = {} end
    return sessions[id]
end

local function ready(id)
    -- Fail closed if an older host has no readiness API.
    if not Open77.ready or type(Open77.ready.isReady) ~= "function"
        or not Open77.ready.isReady(id) then return false end
    local ok, life = Admin.placeable(id)
    return ok and life.phase == "alive"
end

local function running(batch)
    if batch.cancelled then return false end
    if batch.actor > 0 then
        if session(batch.actor) ~= batch.session then batch.cancelled = "operator disconnected"
        elseif not Admin.allowed(batch.actor, batch.command) then batch.cancelled = "permission revoked" end
    end
    return not batch.cancelled
end

local function result(batch)
    local text = string.format("%s %s: %d/%d completed, %d skipped, %d failed, %d not processed",
        batch.label, batch.cancelled and ("stopped (" .. batch.cancelled .. ")") or "finished",
        batch.done, batch.total, batch.skipped, batch.failed,
        batch.total - batch.done - batch.skipped - batch.failed)
    if #batch.errors > 0 then text = text .. " -- " .. table.concat(batch.errors, "; ") end
    local ok = not batch.cancelled and batch.failed == 0
    Admin.record(batch.actor, batch.command .. ".result", text, ok)
    Admin.output(batch.actor > 0 and session(batch.actor) == batch.session and batch.actor or 0, batch.raw, ok, text)
end

local function failure(batch, id, reason)
    batch.failed = batch.failed + 1
    if #batch.errors < 5 then batch.errors[#batch.errors + 1] = tostring(id) .. ": " .. tostring(reason) end
end

local function start(source, raw, command, label, targets, worker)
    if active then return Admin.output(source, raw, false, "A server action is already running. Use admin.bulk.cancel."), "busy" end
    if Admin.nowMs() < nextRunAt then return Admin.output(source, raw, false, "Server actions are cooling down; try again shortly."), "cooldown" end
    if #targets == 0 then return Admin.output(source, raw, true, label .. ": no eligible targets."), "empty" end
    local batch = { actor = source, session = source > 0 and session(source) or nil,
        command = command, raw = raw, label = label, total = #targets,
        done = 0, skipped = 0, failed = 0, errors = {} }
    active = batch
    Admin.output(source, raw, true, string.format("%s started: %d target(s). Use admin.bulk.cancel to stop.", label, #targets))
    CreateThread(function()
        local ok, reason = pcall(worker, batch, targets)
        if not ok then batch.cancelled = "worker error"; Admin.log(label .. ": " .. tostring(reason)) end
        active = nil
        nextRunAt = Admin.nowMs() + Config.cooldownMs
        result(batch)
    end)
    return true, label .. " queued " .. #targets
end

-- Six slots in ring one, twelve in ring two, etc. Both radial and tangential
-- separation are >= spacing. No terrain probe exists here: use open, level ground.
local function landing(origin, index)
    local ring = 1
    while index > 6 * ring do index = index - 6 * ring; ring = ring + 1 end
    local angle = (index - 1) * 2 * math.pi / (6 * ring)
    return { x = origin.x + math.cos(angle) * Config.spacing * ring,
        y = origin.y + math.sin(angle) * Config.spacing * ring, z = origin.z }
end

Admin.register("admin.bulk.tpall", {
    help = "Bring all other ready, alive players to spaced positions around you, one at a time. Stand on open ground.",
    params = { { name = "confirm" } }, requiresPlayer = true, mutation = true,
    handler = function(source, args, raw, _, invokedAs)
        if args.n ~= 1 or args[1] ~= "confirm" then
            return Admin.output(source, raw, false, "usage: " .. invokedAs .. " confirm -- moves all ready, alive players across all buckets; stand on open, level ground")
        end
        if not ready(source) then return Admin.output(source, raw, false, "You must be alive and gameplay-ready.") end
        if Open77.vehicles.getPlayerSeat(source) then return Admin.output(source, raw, false, "Leave your vehicle before TpAll.") end
        local at = Open77.players.position(source)
        if not at or not Admin.finiteNumber(at.x) or not Admin.finiteNumber(at.y) or not Admin.finiteNumber(at.z) then
            return Admin.output(source, raw, false, "Your position is unavailable.")
        end
        -- Freeze the rendezvous at invocation; walking away never drags it around.
        local origin = { x = at.x, y = at.y, z = at.z, bucket = at.bucket or 0 }
        local targets = {}
        for _, id in ipairs(Open77.players.all()) do
            if id ~= source and ready(id) then targets[#targets + 1] = { id = id, session = session(id) } end
        end
        table.sort(targets, function(a, b) return a.id < b.id end)
        return start(source, raw, invokedAs, "TpAll", targets, function(batch, list)
            for index, target in ipairs(list) do
                if index > 1 then Wait(Config.teleportIntervalMs) end
                if not running(batch) then break end
                if not ready(batch.actor) then batch.cancelled = "operator is no longer ready/alive"; break end
                if session(target.id) ~= target.session or not ready(target.id) then batch.skipped = batch.skipped + 1
                else
                    local ok, reason = Admin.placeAt(target.id, landing(origin, index), 0, origin.bucket, "tpall")
                    if ok then
                        batch.done = batch.done + 1
                        Admin.announce(target.id, "An administrator gathered the ready players here (TpAll).")
                    else failure(batch, target.id, reason) end
                end
                if index % 10 == 0 and index < #list then
                    Admin.output(batch.actor, raw, true, string.format("TpAll: %d/%d processed (%d moved).", index, #list, batch.done))
                end
            end
        end)
    end,
})

local function occupantIds(vehicle)
    local ids = {}
    for _, occupant in ipairs(vehicle.occupants or {}) do
        local id = tonumber(type(occupant) == "table" and occupant.playerId or occupant)
        if id then ids[#ids + 1] = id end
    end
    return ids
end

Admin.register("admin.bulk.dvall", {
    help = "Remove ALL network vehicles, across resources and buckets, after occupants exit. Explicit confirmation required.",
    params = { { name = "confirm" } }, mutation = true,
    handler = function(source, args, raw, _, invokedAs)
        if args.n ~= 1 or args[1] ~= "confirm" then
            return Admin.output(source, raw, false, "usage: " .. invokedAs .. " confirm -- removes ALL network vehicles; occupants are forced out first")
        end
        local targets = {}
        for _, vehicle in ipairs(Open77.vehicles.all() or {}) do targets[#targets + 1] = vehicle.id end
        table.sort(targets)
        return start(source, raw, invokedAs, "DVAll", targets, function(batch, list)
            for index, id in ipairs(list) do
                if index > 1 then Wait(Config.vehicleIntervalMs) end
                if not running(batch) then break end
                local vehicle = Open77.vehicles.get(id)
                local refusal
                if vehicle then
                    local occupants = occupantIds(vehicle)
                    for _, player in ipairs(occupants) do
                        local ok, reason = Open77.vehicles.forcePlayerOutOfVehicle(player, id)
                        if not ok then refusal = "exit rejected: " .. tostring(reason); break end
                        Admin.announce(player, "An administrator is clearing vehicles (DVAll). You are being moved out before removal.")
                    end
                    local waited = 0
                    while not refusal and vehicle and #occupantIds(vehicle) > 0 and waited < Config.exitTimeoutMs do
                        Wait(100); waited = waited + 100
                        if not running(batch) then break end
                        vehicle = Open77.vehicles.get(id)
                    end
                end
                if not running(batch) then break end
                vehicle = Open77.vehicles.get(id)
                if not vehicle then batch.skipped = batch.skipped + 1
                elseif refusal then failure(batch, id, refusal)
                elseif #occupantIds(vehicle) > 0 then failure(batch, id, "still occupied; left intact")
                else
                    -- world.vehicles grants cross-resource authority on current hosts.
                    -- There is deliberately no ownership/ledger/distance/bucket filter.
                    local ok, reason = Open77.vehicles.remove(id)
                    if ok then
                        batch.done = batch.done + 1
                        Admin.vehicles.ledgerDrop(id)
                        Admin.vehicles.governor.instance[id] = nil
                    else failure(batch, id, reason or "remove rejected") end
                end
                if index % 25 == 0 and index < #list then
                    Admin.output(batch.actor, raw, true, string.format("DVAll: %d/%d processed (%d removed).", index, #list, batch.done))
                end
            end
        end)
    end,
})

Admin.register("admin.bulk.cancel", {
    help = "Stop the current server-wide action. Completed moves/removals cannot be undone.",
    mutation = true,
    handler = function(source, _, raw)
        if not active then return Admin.output(source, raw, false, "No server action is running.") end
        active.cancelled = "cancelled by " .. tostring(source)
        return Admin.output(source, raw, true, "Cancellation requested. Completed actions are not rolled back."), active.label
    end,
})
