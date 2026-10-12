-- open77_admin -- the Vehicles tab's server half: a spawn ledger, the
-- occupancy gate, and the authoritative mirror of the performance governor.
--
-- ===========================================================================
-- TWO THINGS ABOUT THE GOVERNOR THAT SHAPE THIS FILE
-- ===========================================================================
-- 1. It is CLIENT-LOCAL. `Open77.vehicles.setPerformance` clamps a throttle
--    float inside the client that simulates the vehicle; it is not
--    server-authoritative physics. So a cap must be broadcast to every client
--    AND replayed to every joiner, and this file holds the authoritative copy.
--    It is balance, not anti-cheat: a modified client can decline, and the
--    server cannot corroborate -- its vehicle snapshot carries no velocity.
--
-- 2. There is NO read-back in Lua. `TryGetPerformanceProfile` and
--    `GetGovernorDiagnostics` exist natively but are not bound, so the mirror
--    below is the only place that knows what is in force. Losing it means
--    losing the ability to clear what you set.
--
-- The native itself landed after 2.31.0+op77.7 (it is in the current release
-- client). On a build without it the calls simply are not there, so the client
-- half probes and reports, and this file refuses to send governor traffic to a
-- client that said it cannot apply it.
-- ===========================================================================

local Config, Catalog = Admin.Config, Admin.Catalog
local output, push = Admin.output, Admin.push
local finiteNumber, round = Admin.finiteNumber, Admin.round
local resolveTarget = Admin.resolveTarget

-- ---------------------------------------------------------------------------
-- The ledger
--
-- Current hosts grant cross-resource mutation through world.vehicles. This
-- ledger scopes legacy "mine" / "all" and cleanup, not global DVAll; it also
-- lets the panel show "6 spawned". It is not a permission boundary.
-- ---------------------------------------------------------------------------
local spawned = {}          -- [vehicleId] = { owner, record, atMs }
local ownedCount = {}       -- [playerId]  = number

-- Declared up here rather than beside the governor commands because the ledger
-- teardown below has to reach it, and in one Lua state a `local` is only
-- visible after its declaration -- referencing it earlier would silently make
-- it a nil global.
--
-- `global` is a third tier, WEAKEST of the three: it caps every vehicle this
-- platform spawns that has neither an instance nor a record profile of its
-- own. There is no native "default" binding in Lua, so the client half
-- synthesises it out of record-class profiles as records appear in the world
-- -- see client/main.lua. Held as a field, nil when unset, so the replay
-- payload carries it for free.
local governor = { instance = {}, class = {}, global = nil }

local function forgetGovernor(vehicleId)
    governor.instance[vehicleId] = nil
end

local function ledgerAdd(vehicleId, owner, record)
    spawned[vehicleId] = { owner = owner, record = record, atMs = Admin.nowMs() }
    if owner > 0 then ownedCount[owner] = (ownedCount[owner] or 0) + 1 end
end

local function ledgerDrop(vehicleId)
    local entry = spawned[vehicleId]
    if entry == nil then return end
    if entry.owner > 0 and ownedCount[entry.owner] ~= nil then
        ownedCount[entry.owner] = math.max(0, ownedCount[entry.owner] - 1)
    end
    spawned[vehicleId] = nil
end

-- Whatever removed it -- this resource, a gamemode, a despawn sweep -- the
-- ledger has to agree with the world.
AddEventHandler("onVehicleRemoved", function(vehicleIdStr)
    local vehicleId = tonumber(vehicleIdStr)
    if vehicleId == nil then return end
    ledgerDrop(vehicleId)
    -- The mirror has to go with it, and this is the path that matters: the two
    -- deliberate removals below already pair the two, but a vehicle removed by
    -- a gamemode or a despawn sweep would otherwise leave an instance profile
    -- behind forever -- counted by admin.server.status, shipped in every
    -- roster, and REPLAYED to every joining client, capping a dead id.
    forgetGovernor(vehicleId)
end)

-- ---------------------------------------------------------------------------
-- The occupancy gate
--
-- This codebase has already paid for getting this wrong. `setTransform` is a
-- teleport PLUS a physics-lease revoke PLUS an authority-epoch bump; on a car
-- with a driver in it the solver resolves the interpenetration it creates by
-- throwing the car -- "la voiture spawn dans le sol et se retourne quand ça
-- commence", every match, for weeks.
--
-- The gate reads the LIVE snapshot at the moment of the call, never a cached
-- flag and never the list the panel happens to be showing: the case that
-- matters is exactly the one where somebody boarded in the seconds nobody was
-- looking.
-- ---------------------------------------------------------------------------
local function occupants(vehicleId)
    local snapshot = Open77.vehicles.get(vehicleId)
    if type(snapshot) ~= "table" then return nil, "vehicle " .. vehicleId .. " is unknown" end
    local list = {}
    if type(snapshot.occupants) == "table" then
        for _, occupant in ipairs(snapshot.occupants) do
            -- Occupant ids arrive as strings.
            local playerId = tonumber(type(occupant) == "table" and occupant.playerId or occupant)
            if playerId ~= nil then list[#list + 1] = playerId end
        end
    end
    return list, snapshot
end

local function requireEmpty(vehicleId, what)
    local list, snapshot = occupants(vehicleId)
    if list == nil then return nil, snapshot end
    if #list > 0 then
        local names = {}
        for _, playerId in ipairs(list) do
            names[#names + 1] = (Open77.players.name(playerId) or "?") .. " (" .. playerId .. ")"
        end
        return nil, string.format("%s refused: %s aboard vehicle %d",
            what, table.concat(names, ", "), vehicleId)
    end
    return snapshot
end

-- ---------------------------------------------------------------------------
-- The governor mirror
-- ---------------------------------------------------------------------------
local function governorClients()
    local targets = {}
    for playerId, entry in pairs(Admin.players) do
        if entry.capabilities ~= nil and entry.capabilities.governor == true then
            targets[#targets + 1] = playerId
        end
    end
    return targets
end

local function broadcastGovernor(scope, key, profile)
    for _, playerId in ipairs(governorClients()) do
        TriggerClientEvent("open77_admin:governor", playerId, "set", scope, key, profile)
    end
end

--- Replay the whole mirror to one client.
---
--- This is load-bearing, not a nicety: the governor is client-local state, so a
--- player who joins after a cap was set would drive an ungoverned car in a
--- world where everybody else's is capped. Called from the `hello` handler in
--- server/main.lua, which fires on every client resource start and on
--- worldReady -- so it covers a fresh join, a reconnect and a hot reload.
---
--- Re-applying an identical profile is idempotent natively (the maps are keyed
--- writes), so the repeat costs nothing but a packet, and an empty mirror costs
--- not even that.
local function replayGovernor(playerId)
    if next(governor.instance) == nil and next(governor.class) == nil
        and governor.global == nil then return end
    TriggerClientEvent("open77_admin:governor", playerId, "replay", governor)
end
Admin.replayGovernor = replayGovernor

--- Validate a profile against the PANEL's bounds, which are tighter than the
--- native's. The native accepts topSpeed up to 1000 km/h; nothing in the
--- catalogue can use more than 300, and an operator who types 900 has made a
--- mistake rather than a decision.
---
--- accelerationScale cannot exceed 1.0. That is not a policy choice here -- the
--- native clamps it, by construction, so the governor can only ever reduce
--- throttle and can never be a cheat. There is no boost to offer.
local function readProfile(args, index)
    local bounds = Config.vehicles.governor
    local top = finiteNumber(args[index])
    if top == nil or top < bounds.topSpeedKph.min or top > bounds.topSpeedKph.max then
        return nil, string.format("top speed must be %.0f..%.0f km/h (0 leaves the top end alone)",
            bounds.topSpeedKph.min, bounds.topSpeedKph.max)
    end
    local taper = bounds.taperKph.default
    if args[index + 1] ~= nil then
        taper = finiteNumber(args[index + 1])
        if taper == nil or taper < bounds.taperKph.min or taper > bounds.taperKph.max then
            return nil, string.format("taper must be %.0f..%.0f km/h",
                bounds.taperKph.min, bounds.taperKph.max)
        end
    end
    local scale = bounds.accelerationScale.default
    if args[index + 2] ~= nil then
        scale = finiteNumber(args[index + 2])
        if scale == nil or scale < bounds.accelerationScale.min or scale > bounds.accelerationScale.max then
            return nil, string.format("throttle authority must be %.2f..%.2f (1 is stock; there is no boost)",
                bounds.accelerationScale.min, bounds.accelerationScale.max)
        end
    end
    return { topSpeedKph = top, taperKph = taper, accelerationScale = scale }
end

--- Which vehicle does "here" mean for this operator?
---
--- The one he is ABOARD always wins, read from the live snapshot exactly like
--- the occupancy gate -- never from the panel's stale list. On foot it falls
--- back to the nearest vehicle in HIS routing bucket, bounded by
--- `Config.vehicles.nearRadius`: past that the operator cannot tell which car
--- he is about to cap, and capping a car he cannot see is the surprise these
--- commands exist to avoid.
---
--- Returns `vehicleId, description` on success and `nil, reason` on failure,
--- the description naming how the vehicle was chosen so the reply -- and the
--- audit line built from it -- says what was actually acted on.
local function resolveOperatorVehicle(source)
    if source == nil or source <= 0 then
        return nil, "'here' targets the sending player's vehicle and is unavailable from the console"
    end
    local origin = Open77.players.position(source)
    if origin == nil then
        return nil, "your position is not readable yet -- try again in a moment"
    end
    local nearest, nearestDistance
    for _, snapshot in ipairs(Open77.vehicles.all() or {}) do
        if type(snapshot.occupants) == "table" then
            for _, occupant in ipairs(snapshot.occupants) do
                -- Occupant ids arrive as strings, exactly as in `occupants`.
                local playerId = tonumber(type(occupant) == "table" and occupant.playerId or occupant)
                if playerId == source then
                    return snapshot.id, string.format("your vehicle %d", snapshot.id)
                end
            end
        end
        if snapshot.x ~= nil and (snapshot.bucket or 0) == (origin.bucket or 0) then
            local dx = snapshot.x - origin.x
            local dy = snapshot.y - origin.y
            local dz = snapshot.z - origin.z
            local distance = math.sqrt(dx * dx + dy * dy + dz * dz)
            if nearest == nil or distance < nearestDistance then
                nearest, nearestDistance = snapshot.id, distance
            end
        end
    end
    local radius = Config.vehicles.nearRadius or 40.0
    if nearest ~= nil and nearestDistance <= radius then
        return nearest, string.format("nearest vehicle %d (%.1f m away)", nearest, nearestDistance)
    end
    return nil, string.format(
        "you are not in a vehicle and none is within %.0f m", radius)
end

-- ---------------------------------------------------------------------------
-- Rated top speed cache
--
-- `Open77.vehicles.ratedTopSpeed(id)` reads the record's TweakDB gearing, so
-- the number is effectively a property of the RECORD -- but it is only
-- readable from a live instance, and only on the client. There is no
-- record-level query anywhere.
--
-- So the catalogue ships with the three figures that were actually measured,
-- and this fills in as records appear in the world. It is a CLIENT-REPORTED
-- HINT used for one thing: sorting a 1372-row list. It is never authority, a
-- record with no reading shows a dash and sorts last, and nothing here ever
-- estimates a number.
-- ---------------------------------------------------------------------------
RegisterNetEvent("open77_admin:rated", function(record, kph)
    if type(record) ~= "string" or Catalog.position(record) == nil then return end
    local value = finiteNumber(kph)
    -- Clamp to a plausible band and take the first writer.
    --
    -- Be honest about what that buys. Two honest clients reading the same
    -- gearing agree, so churn is the thing being bounded -- but first-write-
    -- wins means the first LIAR wins too, and an honest later reading cannot
    -- correct it. That is an acceptable trade only because the figure is
    -- decoration: it orders one column and is never authority for anything.
    -- The moment something depends on it, this needs a quorum or a server-side
    -- read instead.
    if value == nil or value < 10.0 or value > 600.0 then return end
    if Catalog.ratedTopSpeed[record] == nil then
        Catalog.ratedTopSpeed[record] = round(value, 0)
    end
end)

-- ---------------------------------------------------------------------------
-- Spawn
-- ---------------------------------------------------------------------------
local function resolveRecord(token)
    if type(token) ~= "string" or token == "" then return nil, "no vehicle named" end
    local alias = Config.vehicles.aliases[token:lower()]
    if alias ~= nil then return alias end
    -- Any of the 1372 catalogue records, verbatim. The catalogue index is the
    -- validity test: a client may name any string, and only a string that is
    -- in the catalogue reaches Open77.vehicles.create.
    if Catalog.position(token) ~= nil then return token end
    return nil, "unknown vehicle -- use a catalogue record or one of: " ..
        (function()
            local names = {}
            for name in pairs(Config.vehicles.aliases) do names[#names + 1] = name end
            table.sort(names)
            return table.concat(names, ", ")
        end)()
end

--- `ownerId` is who the vehicle belongs to, which is NOT always `source`:
--- admin.veh.give hands one to somebody else. Charging it to the operator
--- instead would eat their cap, list it as theirs, and leave the recipient's
--- own `/admin.veh.remove mine` unable to find it.
local function spawnFor(source, ownerId, record, position, yaw, raw)
    ownerId = (ownerId ~= nil and ownerId > 0) and ownerId or 0
    if ownerId > 0 then
        local used = ownedCount[ownerId] or 0
        if used >= Config.limits.vehiclesPerOperator then
            return output(source, raw, false, string.format(
                "%s already %s %d vehicles out (cap %d) -- /admin.veh.remove all or /admin.world.cleanup",
                ownerId == source and "you" or ("player " .. ownerId),
                ownerId == source and "have" or "has",
                used, Config.limits.vehiclesPerOperator))
        end
    end

    local vehicleId, reason = Open77.vehicles.create({
        record = record,
        position = position,
        yaw = yaw or 0.0,
        bucket = position.bucket or 0,
    })
    if vehicleId == nil then
        return output(source, raw, false, "vehicle create rejected: " .. tostring(reason))
    end
    ledgerAdd(vehicleId, ownerId, record)

    -- A class profile already in force applies to this spawn on its own -- the
    -- native resolves instance -> record -> default per vehicle, per frame --
    -- so nothing is re-sent here.
    local entry = Catalog.entry(record)
    return output(source, raw, true, string.format("vehicle %d spawned -- %s",
        vehicleId, entry and entry.name or record)), string.format("%d:%s", vehicleId, record)
end

Admin.register("admin.veh.spawn", {
    help = "Spawn a vehicle beside you, from the full 2.31 catalogue.",
    params = {
        { name = "record|alias", help = "A Vehicle.* record, or a short alias." },
        { name = "x", optional = true }, { name = "y", optional = true },
        { name = "z", optional = true }, { name = "yaw", optional = true },
    },
    requiresPlayer = true, mutation = true,
    handler = function(source, args, raw)
        local record, reason = resolveRecord(args[1])
        if record == nil then return output(source, raw, false, reason) end

        local position
        if args.n >= 4 then
            local x, y, z = finiteNumber(args[2]), finiteNumber(args[3]), finiteNumber(args[4])
            if x == nil or y == nil or z == nil then
                return output(source, raw, false, "invalid coordinates")
            end
            local mine = Open77.players.position(source)
            position = { x = x, y = y, z = z, bucket = mine and mine.bucket or 0 }
        else
            local mine = Open77.players.position(source)
            if mine == nil then
                return output(source, raw, false, "your position is not readable yet -- try again in a moment")
            end
            local offset = Config.vehicles.spawnOffset
            position = {
                x = mine.x + offset.x, y = mine.y + offset.y, z = mine.z + offset.z,
                bucket = mine.bucket or 0,
            }
        end
        local yaw = args.n >= 5 and finiteNumber(args[5]) or 0.0
        return spawnFor(source, source, record, position, yaw, raw)
    end,
})

Admin.register("admin.veh.give", {
    help = "Spawn a vehicle beside another player.",
    params = { { name = "playerId" }, { name = "record|alias" } },
    mutation = true,
    handler = function(source, args, raw)
        local playerId, reason = resolveTarget(source, args[1])
        if playerId == nil then return output(source, raw, false, reason) end
        local record, recordError = resolveRecord(args[2])
        if record == nil then return output(source, raw, false, recordError) end
        local theirs = Open77.players.position(playerId)
        if theirs == nil then
            return output(source, raw, false, "player " .. playerId .. " has no readable position yet")
        end
        local offset = Config.vehicles.spawnOffset
        local ok = spawnFor(source, playerId, record, {
            x = theirs.x + offset.x, y = theirs.y + offset.y, z = theirs.z + offset.z,
            bucket = theirs.bucket or 0,
        }, 0.0, raw)
        if ok then Admin.announce(playerId, "An administrator delivered a vehicle to you.") end
        return ok, string.format("%d:%s", playerId, record)
    end,
})

-- ---------------------------------------------------------------------------
-- Remove, repair, flags
-- ---------------------------------------------------------------------------
local function cooperative(source, vehicleId, operation, value, enabled)
    local snapshot = Open77.vehicles.get(vehicleId)
    if not snapshot or snapshot.resource ~= "freeroam" then return false, "not_owner" end
    local pending, reason = Open77.exports.call("freeroam", "adminVehicleAction", source, vehicleId, operation, value, enabled)
    if not pending then return false, reason end
    return pending:await()
end

Admin.register("admin.veh.remove", {
    help = "Remove a vehicle, all of yours, or every one this resource spawned.",
    params = { { name = "vehicleId|mine|all", optional = true } },
    mutation = true,
    handler = function(source, args, raw)
        local token = args.n >= 1 and tostring(args[1]):lower() or "mine"
        local targets = {}
        if token == "all" then
            for vehicleId in pairs(spawned) do targets[#targets + 1] = vehicleId end
        elseif token == "mine" then
            for vehicleId, entry in pairs(spawned) do
                if entry.owner == source then targets[#targets + 1] = vehicleId end
            end
        else
            local vehicleId = tonumber(token)
            if vehicleId == nil then
                return output(source, raw, false, "usage: admin.veh.remove <vehicleId|mine|all>")
            end
            targets[1] = vehicleId
        end
        if #targets == 0 then return output(source, raw, false, "no vehicle to remove") end

        local removed, skipped = 0, {}
        for _, vehicleId in ipairs(targets) do
            local _, refusal = requireEmpty(vehicleId, "remove")
            if refusal ~= nil and type(refusal) == "string" then
                skipped[#skipped + 1] = refusal
            else
                local ok, reason = Open77.vehicles.remove(vehicleId)
                if not ok then ok, reason = cooperative(source, vehicleId, "remove") end
                if ok then
                    ledgerDrop(vehicleId)
                    forgetGovernor(vehicleId)
                    removed = removed + 1
                else
                    skipped[#skipped + 1] = string.format("vehicle %d: %s", vehicleId, tostring(reason or "remove_failed"))
                end
            end
        end
        local text = string.format("%d vehicle(s) removed", removed)
        if #skipped > 0 then text = text .. " -- " .. table.concat(skipped, "; ") end
        return output(source, raw, removed > 0, text), tostring(removed)
    end,
})

Admin.register("admin.veh.repair", {
    help = "Repair a vehicle. Scopes: glass body lights tires visual mechanical full.",
    params = { { name = "vehicleId" }, { name = "scope", optional = true } },
    mutation = true,
    handler = function(source, args, raw)
        local vehicleId = args.n >= 1 and tonumber(args[1]) or nil
        if vehicleId == nil then
            return output(source, raw, false, "usage: admin.veh.repair <vehicleId> [scope]")
        end
        local scope = args.n >= 2 and tostring(args[2]):lower() or "full"
        local list, snapshot = occupants(vehicleId)
        if list == nil then return output(source, raw, false, snapshot) end

        -- `full` and `mechanical` may escalate to a controlled respawn, which
        -- on a car with a driver in it is a destroy. Refuse and say what does
        -- work, rather than doing something surprising.
        if #list > 0 and not Config.vehicles.occupiedSafeRepairScopes[scope] then
            return output(source, raw, false, string.format(
                "'%s' repair is unsafe with somebody aboard vehicle %d -- try 'visual', 'body' or 'glass'",
                scope, vehicleId))
        end

        local ok, reason = Open77.vehicles.repair(vehicleId, scope)
        if not ok then ok, reason = cooperative(source, vehicleId, "repair", scope) end
        if not ok then return output(source, raw, false, "repair rejected: " .. tostring(reason)) end
        return output(source, raw, true, string.format("vehicle %d repaired (%s)", vehicleId, scope)),
            string.format("%d:%s", vehicleId, scope)
    end,
})

--- `flags` is an integer BITMASK on the wire, not a table of booleans, and
--- `Open77.vehicles.flags.<name>` are the mask constants. Read-modify-write is
--- the only correct shape: patching a flags integer replaces the whole set, so
--- computing it from anything but the live snapshot silently clears whatever
--- else was on.
local function flagMask(name)
    local masks = Open77.vehicles.flags
    return type(masks) == "table" and masks[name] or nil
end

Admin.register("admin.veh.flag", {
    help = "Toggle a vehicle flag. Safe with somebody aboard.",
    params = {
        { name = "vehicleId" },
        { name = "flag", help = table.concat(Config.vehicles.flags, " ") },
        { name = "on|off", optional = true },
    },
    mutation = true,
    handler = function(source, args, raw)
        local vehicleId = args.n >= 1 and tonumber(args[1]) or nil
        local flag = args.n >= 2 and tostring(args[2]) or nil
        if vehicleId == nil or flag == nil then
            return output(source, raw, false, "usage: admin.veh.flag <vehicleId> <" ..
                table.concat(Config.vehicles.flags, "|") .. "> [on|off]")
        end
        local allowed = false
        for _, candidate in ipairs(Config.vehicles.flags) do
            if candidate == flag then allowed = true break end
        end
        local mask = allowed and flagMask(flag) or nil
        if mask == nil then
            return output(source, raw, false, "unknown flag -- one of: " ..
                table.concat(Config.vehicles.flags, ", "))
        end
        local snapshot = Open77.vehicles.get(vehicleId)
        if type(snapshot) ~= "table" then
            return output(source, raw, false, "vehicle " .. vehicleId .. " is unknown")
        end
        local bits = math.floor(tonumber(snapshot.flags) or 0)
        local current = (bits & mask) ~= 0
        local enable
        if args.n >= 3 then
            local token = tostring(args[3]):lower()
            if token == "on" or token == "1" or token == "true" then enable = true
            elseif token == "off" or token == "0" or token == "false" then enable = false
            else return output(source, raw, false, "expected on or off") end
        else
            enable = not current
        end
        local next_ = enable and (bits | mask) or (bits & ~mask)
        local ok, reason = Open77.vehicles.update(vehicleId, { flags = next_ })
        if not ok then ok, reason = cooperative(source, vehicleId, "flag", flag, enable) end
        if not ok then return output(source, raw, false, "rejected: " .. tostring(reason)) end
        return output(source, raw, true, string.format("vehicle %d %s %s",
            vehicleId, flag, enable and "on" or "off")),
            string.format("%d:%s=%s", vehicleId, flag, tostring(enable))
    end,
})

-- ---------------------------------------------------------------------------
-- The governor commands
-- ---------------------------------------------------------------------------
local function governorAvailable()
    return #governorClients() > 0
end

Admin.register("admin.veh.speed", {
    help = "Cap a vehicle's top speed and throttle. A record caps EVERY car of that model.",
    params = {
        { name = "vehicleId|record", help = "A number for one car, a Vehicle.* record for the model." },
        { name = "topSpeedKph", help = "0 leaves the top end alone." },
        { name = "taperKph", optional = true },
        { name = "throttle", help = "0.1..1.0; 1 is stock. There is no boost.", optional = true },
    },
    mutation = true,
    handler = function(source, args, raw)
        if args.n < 2 then
            return output(source, raw, false,
                "usage: admin.veh.speed <vehicleId|record> <topSpeedKph> [taperKph] [throttle]")
        end
        local profile, reason = readProfile(args, 2)
        if profile == nil then return output(source, raw, false, reason) end

        if not governorAvailable() then
            -- Say so plainly. A control that appears to work and does not is
            -- worse than one that refuses.
            return output(source, raw, false,
                "no connected client has the vehicle governor -- it ships in the next client build")
        end

        local vehicleId = tonumber(args[1])
        if vehicleId ~= nil then
            local snapshot = Open77.vehicles.get(vehicleId)
            if type(snapshot) ~= "table" then
                return output(source, raw, false, "vehicle " .. vehicleId .. " is unknown")
            end
            -- Deliberately NOT gated on occupancy: a performance profile only
            -- scales a float the drive update was about to read. Nothing is
            -- teleported and no physics lease moves, so it is safe on a car
            -- somebody is driving -- unlike setTransform, remove or a full
            -- repair.
            governor.instance[vehicleId] = profile
            broadcastGovernor("instance", vehicleId, profile)
            return output(source, raw, true, string.format(
                "vehicle %d capped at %.0f km/h, throttle %.2f (this car only)",
                vehicleId, profile.topSpeedKph, profile.accelerationScale)),
                string.format("instance %d", vehicleId)
        end

        local record = tostring(args[1])
        if Catalog.position(record) == nil then
            return output(source, raw, false, "unknown record -- pass a vehicleId or a catalogue Vehicle.* record")
        end
        governor.class[record] = profile
        broadcastGovernor("class", record, profile)
        return output(source, raw, true, string.format(
            "EVERY %s capped at %.0f km/h, throttle %.2f -- server-wide, present and future spawns",
            record, profile.topSpeedKph, profile.accelerationScale)),
            string.format("class %s", record)
    end,
})

Admin.register("admin.veh.speed.here", {
    help = "Cap the vehicle you are in -- or the nearest one -- without naming an id.",
    params = {
        { name = "topSpeedKph", help = "0 leaves the top end alone." },
        { name = "taperKph", optional = true },
        { name = "throttle", help = "0.1..1.0; 1 is stock.", optional = true },
    },
    requiresPlayer = true, mutation = true,
    handler = function(source, args, raw)
        if args.n < 1 then
            return output(source, raw, false,
                "usage: admin.veh.speed.here <topSpeedKph> [taperKph] [throttle]")
        end
        local profile, reason = readProfile(args, 1)
        if profile == nil then return output(source, raw, false, reason) end
        if not governorAvailable() then
            return output(source, raw, false,
                "no connected client has the vehicle governor -- it ships in the next client build")
        end
        local vehicleId, how = resolveOperatorVehicle(source)
        if vehicleId == nil then return output(source, raw, false, how) end
        -- From here this IS admin.veh.speed's instance branch: same mirror,
        -- same broadcast, same non-gating on occupancy (a profile only scales
        -- a float the drive update was about to read).
        governor.instance[vehicleId] = profile
        broadcastGovernor("instance", vehicleId, profile)
        return output(source, raw, true, string.format(
            "%s capped at %.0f km/h, throttle %.2f (this car only)",
            how, profile.topSpeedKph, profile.accelerationScale)),
            string.format("instance %d", vehicleId)
    end,
})

Admin.register("admin.veh.speed.global", {
    help = "Cap EVERY vehicle Open77 spawns, whatever its model. The weakest tier.",
    params = {
        { name = "topSpeedKph", help = "The ceiling, in km/h. It cannot make anything faster." },
        { name = "taperKph", optional = true },
        { name = "throttle", help = "0.1..1.0; 1 is stock.", optional = true },
    },
    mutation = true,
    handler = function(source, args, raw)
        if args.n < 1 then
            return output(source, raw, false,
                "usage: admin.veh.speed.global <topSpeedKph> [taperKph] [throttle]")
        end
        local profile, reason = readProfile(args, 1)
        if profile == nil then return output(source, raw, false, reason) end
        -- A neutral profile -- no ceiling, stock throttle -- caps nothing, and
        -- storing one would replay a no-op to every joiner forever. For an
        -- instance that shape has a real use (exempting one car from a record
        -- cap); globally it can only be a misspelt clear, so say so.
        if profile.topSpeedKph <= 0.0 and profile.accelerationScale >= 1.0 then
            return output(source, raw, false,
                "that profile caps nothing -- use admin.veh.speed.clear global to remove the cap")
        end
        if not governorAvailable() then
            return output(source, raw, false,
                "no connected client has the vehicle governor -- it ships in the next client build")
        end
        governor.global = profile
        broadcastGovernor("global", 0, profile)
        return output(source, raw, true, string.format(
            "EVERY spawned vehicle capped at %.0f km/h, throttle %.2f -- server-wide, unless a "
            .. "model or single-car cap overrides it",
            profile.topSpeedKph, profile.accelerationScale)), "global"
    end,
})

Admin.register("admin.veh.speed.clear", {
    help = "Return a vehicle (or 'here'), a model, the global cap, or everything to stock.",
    params = { { name = "vehicleId|record|here|global|all" } },
    mutation = true,
    handler = function(source, args, raw)
        local token = args.n >= 1 and tostring(args[1]) or nil
        if token == nil then
            return output(source, raw, false,
                "usage: admin.veh.speed.clear <vehicleId|record|here|global|all>")
        end
        local targets = governorClients()

        if token:lower() == "all" then
            governor.instance, governor.class, governor.global = {}, {}, nil
            for _, playerId in ipairs(targets) do
                TriggerClientEvent("open77_admin:governor", playerId, "clearAll")
            end
            return output(source, raw, true, "every performance cap cleared"), "all"
        end

        if token:lower() == "global" then
            governor.global = nil
            for _, playerId in ipairs(targets) do
                TriggerClientEvent("open77_admin:governor", playerId, "clear", "global", 0)
            end
            -- Model and single-car caps deliberately survive: they were each a
            -- narrower, later decision than the blanket, and clearing the
            -- blanket is not a reason to lose them.
            return output(source, raw, true,
                "the cap on every spawned vehicle cleared -- model and single-car caps still stand"),
                "global"
        end

        local vehicleId = tonumber(token)
        local resolvedHow
        if vehicleId == nil and token:lower() == "here" then
            vehicleId, resolvedHow = resolveOperatorVehicle(source)
            if vehicleId == nil then return output(source, raw, false, resolvedHow) end
        end
        if vehicleId ~= nil then
            governor.instance[vehicleId] = nil
            for _, playerId in ipairs(targets) do
                TriggerClientEvent("open77_admin:governor", playerId, "clear", "instance", vehicleId)
            end
            -- Worth knowing, and worth saying: clearing an instance profile
            -- does not fall through to a record profile as "no profile" -- the
            -- native resolves instance first and an ABSENT instance profile is
            -- what lets the record one apply again.
            local record = spawned[vehicleId] and spawned[vehicleId].record or nil
            local note = (record ~= nil and governor.class[record] ~= nil)
                and " -- the cap on every " .. record .. " now applies to it again" or ""
            return output(source, raw, true,
                string.format("vehicle %d back to stock%s", vehicleId, note)),
                string.format("instance %d", vehicleId)
        end

        if Catalog.position(token) == nil then
            return output(source, raw, false, "unknown record")
        end
        governor.class[token] = nil
        for _, playerId in ipairs(targets) do
            TriggerClientEvent("open77_admin:governor", playerId, "clear", "class", token)
        end
        return output(source, raw, true, "every " .. token .. " back to stock"),
            string.format("class %s", token)
    end,
})

-- ---------------------------------------------------------------------------
-- Read
-- ---------------------------------------------------------------------------
Admin.register("admin.read.vehicles", {
    help = "Live vehicles, the spawn ledger, and the performance caps in force.",
    handler = function(source, _, raw)
        local origin = source > 0 and Open77.players.position(source) or nil
        local list = {}
        for _, snapshot in ipairs(Open77.vehicles.all() or {}) do
            local vehicleId = snapshot.id
            local ledger = spawned[vehicleId]
            local seated = {}
            if type(snapshot.occupants) == "table" then
                for _, occupant in ipairs(snapshot.occupants) do
                    local playerId = tonumber(type(occupant) == "table" and occupant.playerId or occupant)
                    if playerId ~= nil then
                        seated[#seated + 1] = { playerId = playerId, name = Open77.players.name(playerId) }
                    end
                end
            end
            local record = snapshot.record or (ledger and ledger.record) or nil
            local entry = record and Catalog.entry(record) or nil
            -- The SERVER snapshot carries x, y, z at the top level -- there is
            -- no `position` table, and no orientation at all. (The client
            -- snapshot is a different shape again and carries neither.)
            local position
            if snapshot.x ~= nil then
                position = { x = round(snapshot.x, 2), y = round(snapshot.y, 2), z = round(snapshot.z, 2) }
            end
            local distance
            if origin ~= nil and position ~= nil and origin.bucket == snapshot.bucket then
                local dx, dy, dz = position.x - origin.x, position.y - origin.y, position.z - origin.z
                distance = round(math.sqrt(dx * dx + dy * dy + dz * dz), 1)
            end
            list[#list + 1] = {
                vehicleId = vehicleId,
                record = record,
                name = entry and entry.name or record,
                health = snapshot.health,
                position = position,
                bucket = snapshot.bucket,
                occupants = seated,
                distance = distance,
                mine = ledger ~= nil and ledger.owner == source,
                spawnedHere = ledger ~= nil,
                -- Which tier is actually in force, so the panel never has to
                -- guess. Precedence is instance -> record -> global, and each
                -- tier shadows every weaker one outright.
                governorTier = governor.instance[vehicleId] ~= nil and "instance"
                    or (record ~= nil and governor.class[record] ~= nil and "record"
                    or (governor.global ~= nil and "global" or nil)),
                governorProfile = governor.instance[vehicleId]
                    or (record ~= nil and governor.class[record] or nil)
                    or governor.global,
            }
        end
        table.sort(list, function(a, b) return a.vehicleId < b.vehicleId end)
        push(source, "vehicles", {
            vehicles = list,
            ledger = { used = ownedCount[source] or 0, cap = Config.limits.vehiclesPerOperator },
            governor = {
                available = governorAvailable(),
                clients = #governorClients(),
                instance = governor.instance,
                class = governor.class,
                global = governor.global,
            },
            ratedTopSpeed = Catalog.ratedTopSpeed,
            atMs = Admin.nowMs(),
        })
        if source <= 0 then
            Admin.log(string.format("%d vehicle(s), %d capped instance, %d capped record",
                #list, (function() local n = 0 for _ in pairs(governor.instance) do n = n + 1 end return n end)(),
                (function() local n = 0 for _ in pairs(governor.class) do n = n + 1 end return n end)()))
        end
        return true
    end,
})

Admin.vehicles = {
    spawned = spawned,
    ownedCount = ownedCount,
    governor = governor,
    requireEmpty = requireEmpty,
    ledgerDrop = ledgerDrop,
    governorClients = governorClients,
}
