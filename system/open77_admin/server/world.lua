-- open77_admin -- saved destinations, announcements, cleanup, and the server
-- readout.
--
-- Note what is NOT here: time and weather. `open77_weather` owns those, is
-- present in both deployed resource sets, and its commands are already
-- ACL-gated (`command.weather.*`). The panel's World tab issues `weather.set`
-- and `weather.time.set` through the same `open77:command:execute` channel
-- everything else uses, so each call meets its own permission. Duplicating an
-- authority in order to own a tab would be the wrong trade.

local Config = Admin.Config
local output, push = Admin.output, Admin.push
local placeAt = Admin.placeAt

-- ---------------------------------------------------------------------------
-- Saved destinations
--
-- The seeded list is data in shared/config.lua. Runtime additions live in
-- `Open77.state`, the host-owned bag that outlives this VM: it survives a
-- reload and deliberately does not survive the resource going down, so `stop`
-- still brings the resource back up at its configured defaults. Durable
-- storage would mean the database, which an admin package must not require.
-- ---------------------------------------------------------------------------
local STATE_PROTOCOL = 1

local added = {}          -- [name] = { name, label, position, heading }
local byName = {}

local function reindex()
    byName = {}
    for _, location in ipairs(Config.locations) do
        byName[location.name:lower()] = location
    end
    -- Runtime entries win over the seeded ones with the same name: an operator
    -- who saves "lab" somewhere better meant to replace it.
    for name, location in pairs(added) do
        byName[name] = location
    end
end

-- `Open77.state` is host-owned and has always been present, but this file runs
-- at LOAD time: anything that raises here stops the whole resource, and an
-- admin package that will not start is worse than one that forgets a
-- destination on reload. Both sides are guarded.
local function hasState()
    return type(Open77.state) == "table"
        and type(Open77.state.save) == "function"
        and type(Open77.state.load) == "function"
end

local function saveState()
    if not hasState() then return end
    local list = {}
    for _, location in pairs(added) do list[#list + 1] = location end
    pcall(Open77.state.save, { protocol = STATE_PROTOCOL, locations = list })
end

local function restoreState()
    if not hasState() then return end
    local ok, carried = pcall(Open77.state.load)
    if not ok or type(carried) ~= "table" then return end
    -- A reload can change this file, so a snapshot written by the previous
    -- version of this code is untrusted input. Refuse a shape we do not know
    -- rather than half-adopting it.
    if carried.protocol ~= STATE_PROTOCOL or type(carried.locations) ~= "table" then return end
    for _, location in ipairs(carried.locations) do
        if type(location) == "table" and type(location.name) == "string"
            and type(location.position) == "table" then
            added[location.name:lower()] = location
        end
    end
end

restoreState()
reindex()

local function locationList()
    local list = {}
    for _, location in ipairs(Config.locations) do
        list[#list + 1] = {
            name = location.name, label = location.label,
            position = location.position, heading = location.heading, saved = false,
        }
    end
    for _, location in pairs(added) do
        list[#list + 1] = {
            name = location.name, label = location.label,
            position = location.position, heading = location.heading, saved = true,
        }
    end
    table.sort(list, function(a, b) return a.name < b.name end)
    return list
end

Admin.register("admin.player.at", {
    help = "Teleport a player to a saved destination.",
    params = { { name = "playerId|me" }, { name = "location" } },
    mutation = true,
    handler = function(source, args, raw)
        -- `/goto lab` -- the freeroam spelling -- has one argument. Accept both
        -- shapes rather than making an operator remember which this is.
        local targetToken, locationToken
        if args.n == 1 then
            targetToken, locationToken = "me", args[1]
        elseif args.n == 2 then
            targetToken, locationToken = args[1], args[2]
        else
            return output(source, raw, false, "usage: admin.player.at [playerId] <location>")
        end

        local playerId, reason = Admin.resolveTarget(source, targetToken)
        if playerId == nil then return output(source, raw, false, reason) end
        local location = byName[tostring(locationToken):lower()]
        if location == nil then
            local names = {}
            for _, entry in ipairs(locationList()) do names[#names + 1] = entry.name end
            return output(source, raw, false, "unknown destination -- " .. table.concat(names, ", "))
        end

        local ok, detail = placeAt(playerId, location.position, location.heading or 0.0, nil, "at")
        if not ok then return output(source, raw, false, detail) end
        if playerId ~= source then
            Admin.announce(playerId, "An administrator teleported you to " ..
                (location.label or location.name) .. ".")
        elseif source > 0 then
            -- Moving yourself gets the panel out of the way; see dismissPanel
            -- in server/players.lua.
            TriggerClientEvent("open77_admin:close", source)
        end
        return output(source, raw, true, string.format("player %d -> %s",
            playerId, location.label or location.name)),
            string.format("%d:%s", playerId, location.name)
    end,
})

Admin.register("admin.world.loc.add", {
    help = "Save your current position as a named destination.",
    params = { { name = "name" }, { name = "label", optional = true } },
    requiresPlayer = true, mutation = true,
    handler = function(source, args, raw)
        local name = args.n >= 1 and tostring(args[1]):lower() or nil
        if name == nil or name:match("^[%w_%-]+$") == nil or #name > 32 then
            return output(source, raw, false,
                "usage: admin.world.loc.add <name> [label] -- letters, digits, _ and -, up to 32")
        end
        local position = Open77.players.position(source)
        if position == nil then
            return output(source, raw, false, "your position is not readable yet -- try again in a moment")
        end
        local label = name
        if args.n >= 2 then
            local parts = {}
            for index = 2, args.n do parts[#parts + 1] = tostring(args[index] or "") end
            label = table.concat(parts, " ")
        end
        added[name] = {
            name = name, label = label, heading = 0.0,
            position = { x = position.x, y = position.y, z = position.z },
        }
        saveState()
        reindex()
        return output(source, raw, true, string.format("saved '%s' at %.1f %.1f %.1f",
            name, position.x, position.y, position.z)), name
    end,
})

Admin.register("admin.world.loc.remove", {
    help = "Remove a saved destination. Only runtime ones; the seeded list is config.",
    params = { { name = "name" } },
    mutation = true,
    handler = function(source, args, raw)
        local name = args.n >= 1 and tostring(args[1]):lower() or nil
        if name == nil then return output(source, raw, false, "usage: admin.world.loc.remove <name>") end
        if added[name] == nil then
            return output(source, raw, false,
                "'" .. name .. "' is not a saved destination (the seeded list lives in shared/config.lua)")
        end
        added[name] = nil
        saveState()
        reindex()
        return output(source, raw, true, "removed '" .. name .. "'"), name
    end,
})

-- ---------------------------------------------------------------------------
-- Announce and cleanup
-- ---------------------------------------------------------------------------
Admin.register("admin.world.announce", {
    help = "Broadcast a message to everybody on the server.",
    params = { { name = "text" } },
    mutation = true,
    handler = function(source, args, raw)
        local parts = {}
        for index = 1, args.n do parts[#parts + 1] = tostring(args[index] or "") end
        local text = table.concat(parts, " "):gsub("[%c]", " "):gsub("^%s+", ""):gsub("%s+$", "")
        if text == "" then return output(source, raw, false, "usage: admin.world.announce <text>") end
        -- Admin.trimTo, not sub(1, 239) .. "…": the ellipsis is three UTF-8
        -- bytes, so the naive form lands at 242 and can cut a multi-byte
        -- character in half. Same trap as the kick reason.
        text = Admin.trimTo(text, 240)

        TriggerClientEvent("chat:addMessage", -1, {
            type = "system", author = "ANNOUNCEMENT", text = text, color = { 245, 201, 92 },
        })
        -- The resource owns a renderer on every player's client, including
        -- non-admins. Delivery does not require chat, notifications or a gamemode.
        TriggerClientEvent("open77_admin:announcement", -1, text)
        return output(source, raw, true, "announced: " .. text), text
    end,
})

Admin.register("admin.world.cleanup", {
    help = "Remove every unoccupied vehicle this resource spawned.",
    mutation = true,
    handler = function(source, _, raw)
        local removed, skipped = 0, 0
        local targets = {}
        for vehicleId in pairs(Admin.vehicles.spawned) do targets[#targets + 1] = vehicleId end
        for _, vehicleId in ipairs(targets) do
            local snapshot, refusal = Admin.vehicles.requireEmpty(vehicleId, "cleanup")
            if snapshot == nil and type(refusal) == "string" then
                skipped = skipped + 1
            elseif Open77.vehicles.remove(vehicleId) then
                Admin.vehicles.ledgerDrop(vehicleId)
                Admin.vehicles.governor.instance[vehicleId] = nil
                removed = removed + 1
            end
        end
        return output(source, raw, true, string.format(
            "%d vehicle(s) removed, %d left alone (occupied)", removed, skipped)),
            string.format("%d/%d", removed, skipped)
    end,
})

-- ---------------------------------------------------------------------------
-- Reads
-- ---------------------------------------------------------------------------
local startedAtMs = Admin.nowMs()

-- There is no way to enumerate the resources on a server: `GetResourceState`
-- answers for a name you already know. So the panel's Server card probes the
-- official catalogue by name, which is complete for an Open77 server and
-- simply reports nothing for a third-party one.
local KNOWN_RESOURCES = {
    "open77_admin", "open77_chat", "open77_notifications", "open77_weather",
    "open77_appearance", "open77_equipment", "open77_wardrobe", "open77_death", "open77_vehicles",
    "open77_npcs", "open77_loot", "open77_elevators", "open77_interactions",
    "open77_markers", "open77_worldui", "open77_zones", "open77_nameplates",
    "open77_blips", "open77_groundcircle", "open77_effects", "open77_watermark",
    "open77_vehiclepicker", "open77_debug", "open77_freeroam",
    "freeroam", "pursuit", "pursuit_hud", "race",
}

local function resourceStates()
    local list = {}
    for _, name in ipairs(KNOWN_RESOURCES) do
        -- pcall because this is a read command feeding a panel: a host that
        -- raises on an unknown name must cost one missing row, not the whole
        -- Server card.
        local ok, state = pcall(Open77.resource.state, name)
        if ok and state ~= nil and state ~= "" and state ~= "missing" and state ~= "unknown" then
            list[#list + 1] = { name = name, state = state }
        end
    end
    return list
end

Admin.register("admin.read.world", {
    help = "Saved destinations, routing buckets in use, and resource states.",
    handler = function(source, _, _)
        Admin.prune()
        local buckets, playerCount = {}, 0
        for playerId in pairs(Admin.players) do
            if Open77.players.name(playerId) ~= nil then
                playerCount = playerCount + 1
                local position = Open77.players.position(playerId)
                local bucket = position and position.bucket or 0
                buckets[bucket] = (buckets[bucket] or 0) + 1
            end
        end
        local bucketList = {}
        for bucket, count in pairs(buckets) do
            bucketList[#bucketList + 1] = { bucket = bucket, players = count }
        end
        table.sort(bucketList, function(a, b) return a.bucket < b.bucket end)

        push(source, "world", {
            locations = locationList(),
            buckets = bucketList,
            players = playerCount,
            resources = resourceStates(),
            uptimeMs = Admin.nowMs() - startedAtMs,
            governor = {
                available = #Admin.vehicles.governorClients() > 0,
                clients = #Admin.vehicles.governorClients(),
            },
            atMs = Admin.nowMs(),
        })
        return true
    end,
})

Admin.register("admin.server.status", {
    help = "One-line server readout: players, vehicles, caps, uptime.",
    mutation = false,
    handler = function(source, _, raw)
        Admin.prune()
        local playerCount = 0
        for playerId in pairs(Admin.players) do
            if Open77.players.name(playerId) ~= nil then playerCount = playerCount + 1 end
        end
        local vehicleCount = 0
        for _ in pairs(Admin.vehicles.spawned) do vehicleCount = vehicleCount + 1 end
        local governed = 0
        for _ in pairs(Admin.vehicles.governor.instance) do governed = governed + 1 end
        for _ in pairs(Admin.vehicles.governor.class) do governed = governed + 1 end

        return output(source, raw, true, string.format(
            "players=%d spawned=%d capped=%d destinations=%d governor=%s uptime=%dm",
            playerCount, vehicleCount, governed, #locationList(),
            #Admin.vehicles.governorClients() > 0 and "available" or "unavailable",
            math.floor((Admin.nowMs() - startedAtMs) / 60000)))
    end,
})

Admin.world = { locationList = locationList, byName = function() return byName end }
