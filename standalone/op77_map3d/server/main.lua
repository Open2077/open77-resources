-- op77_map3d server: blips that a server resource places for everyone, one player or
-- a list of players (shops, jobs, mission points...), kept for late joiners and
-- removed with the resource that made them. Also a waypoint or the map, opened for a
-- player. README.md has the API.
local B = Map3DBlip

local blips = {}   -- id -> { blip, owner, targets = nil (everyone) | set of player ids }
local seq = 0

local function players()
    local out = {}
    for _, id in ipairs(GetPlayers()) do out[#out + 1] = tonumber(id) end
    return out
end

local function wire(id, b)
    local out = { id = id }
    for k, v in pairs(b) do out[k] = v end
    return out
end

local function recipients(record)
    if not record.targets then return players() end
    local out = {}
    for id in pairs(record.targets) do out[#out + 1] = id end
    return out
end

local function targetSet(target)
    if target == nil or target == -1 or target == "all" then return nil end
    local set = {}
    if type(target) == "table" then
        for _, id in ipairs(target) do if tonumber(id) then set[tonumber(id)] = true end end
    elseif tonumber(target) then
        set[tonumber(target)] = true
    end
    return set
end

local function push(record, id)
    local payload = { upsert = { wire(id, record.blip) } }
    for _, p in ipairs(recipients(record)) do TriggerClientEvent("op77_map3d:blips", p, payload) end
end

local function add(target, def, owner)
    local b, why = B.normalize(def)
    if not b then return nil, why end
    seq = seq + 1
    local id = "srv:" .. owner .. ":" .. ((type(def.id) == "string" and def.id ~= "") and def.id or tostring(seq))
    if blips[id] then
        -- the same named blip again: retarget and replace it
        for _, p in ipairs(recipients(blips[id])) do TriggerClientEvent("op77_map3d:blips", p, { remove = { id } }) end
    end
    blips[id] = { blip = b, owner = owner, targets = targetSet(target) }
    push(blips[id], id)
    return id
end

local function update(id, patch, owner)
    local r = blips[id]
    if not r then return false, "unknown blip" end
    if owner and r.owner ~= owner then return false, "not your blip" end
    local nb, why = B.patch(r.blip, patch)
    if not nb then return false, why end
    r.blip = nb
    push(r, id)
    return true
end

local function remove(id, owner)
    local r = blips[id]
    if not r or (owner and r.owner ~= owner) then return false end
    blips[id] = nil
    for _, p in ipairs(recipients(r)) do TriggerClientEvent("op77_map3d:blips", p, { remove = { id } }) end
    return true
end

local function clear(owner)
    local gone = {}
    for id, r in pairs(blips) do if r.owner == owner then gone[#gone + 1] = id end end
    for _, id in ipairs(gone) do remove(id) end
    return #gone
end

-- Jamming (shared/jam.lua) for everyone, a player or a list: direct jams and zones.
local jams = {}   -- id -> { jam, owner, targets }

local function addJam(target, def, owner, wantZone)
    local j, why = Map3DJam.normalize(def)
    if not j then return nil, why end
    if wantZone and not j.zone then return nil, "a jam zone needs a position {x, y} and a radius" end
    seq = seq + 1
    local id = "srv:" .. owner .. ":" .. ((type(def) == "table" and type(def.id) == "string" and def.id ~= "") and def.id or ("jam" .. seq))
    if jams[id] then
        for _, p in ipairs(recipients(jams[id])) do TriggerClientEvent("op77_map3d:jams", p, { remove = { id } }) end
    end
    jams[id] = { jam = j, owner = owner, targets = targetSet(target) }
    local payload = { upsert = { wire(id, j) } }
    for _, p in ipairs(recipients(jams[id])) do TriggerClientEvent("op77_map3d:jams", p, payload) end
    return id
end

local function removeJam(id, owner)
    local r = jams[id]
    if not r or (owner and r.owner ~= owner) then return false end
    jams[id] = nil
    for _, p in ipairs(recipients(r)) do TriggerClientEvent("op77_map3d:jams", p, { remove = { id } }) end
    return true
end

local function clearJams(owner)
    local gone = {}
    for id, r in pairs(jams) do if r.owner == owner then gone[#gone + 1] = id end end
    for _, id in ipairs(gone) do removeJam(id) end
    return #gone
end

-- A client that (re)starts the resource asks for its blips.
RegisterNetEvent("op77_map3d:hello", function()
    local src = tonumber(source)
    if not src then return end
    local set = {}
    for id, r in pairs(blips) do
        if not r.targets or r.targets[src] then set[#set + 1] = wire(id, r.blip) end
    end
    TriggerClientEvent("op77_map3d:blips", src, { set = set })
    local jamSet = {}
    for id, r in pairs(jams) do
        if not r.targets or r.targets[src] then jamSet[#jamSet + 1] = wire(id, r.jam) end
    end
    TriggerClientEvent("op77_map3d:jams", src, { set = jamSet })
end)

AddEventHandler("playerDropped", function()
    local src = tonumber(source)
    for _, r in pairs(blips) do if r.targets then r.targets[src] = nil end end
    for _, r in pairs(jams) do if r.targets then r.targets[src] = nil end end
end)

AddEventHandler("onResourceStop", function(name)
    if name ~= GetCurrentResourceName() then clear(name); clearJams(name) end
end)

local function owner() return GetInvokingResource() or GetCurrentResourceName() end

-- target: -1 / nil = everyone, a player id, or a list of player ids
exports("addBlip", function(target, def) return add(target, def, owner()) end)
exports("updateBlip", function(id, patch) return update(id, patch, owner()) end)
exports("removeBlip", function(id) return remove(id, owner()) end)
exports("clearBlips", function() return clear(owner()) end)
-- Staff commands (ACL command.map3d.jam / command.map3d.unjam), also from the console:
--   map3d.jam <playerId|-1> [strength 0..1] [label...]      map3d.unjam [playerId|-1]
local commandJams = {}   -- target -> jam id
RegisterCommand("map3d.jam", function(_, args)
    local target = tonumber(args[1]) or -1
    local strength = tonumber(args[2]) or 1
    local label = (args.n or #args) >= 3 and table.concat(args, " ", 3, args.n or #args) or nil
    local key = tostring(target)
    if commandJams[key] then removeJam(commandJams[key]) end
    commandJams[key] = addJam(target, { id = "cmd:" .. key, strength = strength, label = label }, GetCurrentResourceName(), false)
    print(("[map3d] jammed %s (strength %.2f%s)"):format(target == -1 and "everyone" or ("player " .. key), strength, label and (", " .. label) or ""))
end, true)
RegisterCommand("map3d.unjam", function(_, args)
    local only = args[1] and tostring(tonumber(args[1]) or args[1]) or nil
    local n = 0
    for key, id in pairs(commandJams) do
        if not only or key == only then removeJam(id); commandJams[key] = nil; n = n + 1 end
    end
    print(("[map3d] lifted %d command jam(s)"):format(n))
end, true)

-- Jamming: target -1 / nil = everyone, a player id or a list (like blips)
exports("jam", function(target, def) return addJam(target, def, owner(), false) end)
exports("addJamZone", function(target, def) return addJam(target, def, owner(), true) end)
exports("unjam", function(id) return removeJam(id, owner()) end)
exports("removeJamZone", function(id) return removeJam(id, owner()) end)
exports("clearJams", function() return clearJams(owner()) end)

exports("setWaypoint", function(player, pos)
    if not tonumber(player) then return false end
    TriggerClientEvent("op77_map3d:waypoint", tonumber(player), type(pos) == "table" and { x = pos.x, y = pos.y, z = pos.z } or false)
    return true
end)
exports("openMap", function(player, focus)
    if not tonumber(player) then return false end
    TriggerClientEvent("op77_map3d:open", tonumber(player), type(focus) == "table" and focus or {})
    return true
end)
