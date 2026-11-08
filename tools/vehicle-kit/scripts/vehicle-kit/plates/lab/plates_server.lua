-- LAB ONLY. Open77 plate pack lab (vehicle customization, route W), design @@DESIGN@@.
-- Copied by scripts/vehicle-kit/plates/build-plates.ps1 (revision @@REVISION@@).
-- The preload_mod of this resource adds disabled plate components to the models of the plate
-- spec: the 15 Light RP dealer models, the staff-only Caliburn and every other vanilla player
-- vehicle but the quest variants (Vehicle.q<digits>_*).
-- Setting a TEXT needs the hand-installed lab trigger Open77VehiclePlateLab.reds on every
-- client (and the production client/redscript/Open77VehiclePlate.reds, which ships with the
-- client): the trigger reads the magic paint #040507 and calls the production plate API the
-- way the C++ caller will. Paint replicates, so every viewer, a late joiner included, gets
-- the same text. Every command is restricted: grant the lab account command.vpl.<name>.
local MODELS = @@MODELS@@
local ORDER = @@ORDER@@
-- Must match the alphabet of Open77VehiclePlateLab.reds (index = secondary colour byte).
local ALPHABET = '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ -'
local MAGIC = '#040507'
local cars = {}          -- player -> { vehicle ids }

local function reply(player, raw, ok, text)
    print('[vpl] ' .. text)
    if player and player > 0 then TriggerClientEvent('open77:command:result', player, raw or '', ok == true, text) end
    return ok
end

local function track(player, id)
    cars[player] = cars[player] or {}
    table.insert(cars[player], id)
end

local function removeAll(player)
    local n = 0
    for _, id in ipairs(cars[player] or {}) do
        if Open77.vehicles.get(id) then Open77.vehicles.remove(id); n = n + 1 end
    end
    cars[player] = {}
    return n
end

-- '.' = the car you sit in, else your last lab car; 'all' = every lab car of yours.
local function targets(player, explicit)
    if explicit == 'all' then
        local list = {}
        for _, id in ipairs(cars[player] or {}) do if Open77.vehicles.get(id) then table.insert(list, id) end end
        if #list == 0 then return nil, 'no lab car: spawn one with /vpl.car' end
        return list
    end
    if explicit and explicit ~= '.' then
        local id = tonumber(explicit)
        if id and Open77.vehicles.get(id) then return { id } end
        return nil, 'no vehicle ' .. tostring(explicit)
    end
    local seat = Open77.vehicles.getPlayerSeat(player)
    if seat and seat.vehicleId and Open77.vehicles.get(seat.vehicleId) then return { seat.vehicleId } end
    local mine = cars[player] or {}
    for i = #mine, 1, -1 do if Open77.vehicles.get(mine[i]) then return { mine[i] } end end
    return nil, 'no vehicle: spawn one with /vpl.car, or pass its id'
end

local function spawnRow(player, raw, list, facing)
    local me = Open77.players.get(player)
    if not me or not me.position then return reply(player, raw, false, 'player position not known yet') end
    local heading = me.heading or 0
    local r = math.rad(heading)
    local fx, fy = -math.sin(r), math.cos(r)      -- forward
    local rx, ry = math.cos(r), math.sin(r)       -- right
    local made = {}
    for i, item in ipairs(list) do
        local side = (i - (#list + 1) / 2) * 3.6
        local position = { x = me.position.x + fx * 8 + rx * side, y = me.position.y + fy * 8 + ry * side, z = me.position.z + 0.25 }
        local definition = { record = item.record, position = position, yaw = facing == 'front' and heading + 180 or heading, bucket = me.bucket, ttlMs = 60 * 60 * 1000 }
        if item.appearance and item.appearance ~= '' then definition.appearance = item.appearance end
        local id, why = Open77.vehicles.create(definition)
        if id then
            track(player, id)
            table.insert(made, ('%s=%s (%s)'):format(item.label, tostring(id), tostring(Open77.vehicles.getAppearance(id))))
        else
            table.insert(made, ('%s FAILED %s'):format(item.label, tostring(why)))
        end
    end
    return reply(player, raw, true, 'spawned ' .. table.concat(made, ', ') .. (facing == 'front' and ' facing you' or ' facing away (rear plates)'))
end

-- /vpl.car <model|all> [front] [page]   model player entry, 8 m ahead; all = 16 models in a
-- row, page 1 (the spec's first 16: the dealer models and the Caliburn) by default, page N
-- the next 16 of the spec's order (the other player vehicles)
local PAGE = 16
RegisterCommand('vpl.car', function(player, args, raw)
    if not player or player <= 0 then return print('vpl.car needs a connected player') end
    local key, facing = args[1] or 'galena', args[2]
    local page = math.tointeger(tonumber(args[3] or (facing ~= 'front' and facing) or '1')) or 1
    if facing ~= 'front' then facing = nil end
    local list = {}
    if key == 'all' then
        local pages = math.max(1, math.ceil(#ORDER / PAGE))
        if page < 1 or page > pages then return reply(player, raw, false, ('page %s of %d'):format(tostring(page), pages)) end
        for i = (page - 1) * PAGE + 1, math.min(page * PAGE, #ORDER) do
            local k = ORDER[i]
            table.insert(list, { label = k, record = MODELS[k].record, appearance = MODELS[k].player })
        end
    elseif MODELS[key] then
        list = { { label = key, record = MODELS[key].record, appearance = MODELS[key].player } }
    else
        return reply(player, raw, false, 'unknown model ' .. tostring(key) .. ' (' .. #ORDER .. ' models; all [front] [page])')
    end
    return spawnRow(player, raw, list, facing)
end, true)

-- /vpl.trims <model> [front]   the model's curated trims (Light RP dealer list) in a row
RegisterCommand('vpl.trims', function(player, args, raw)
    if not player or player <= 0 then return print('vpl.trims needs a connected player') end
    local m = MODELS[args[1] or '']
    if not m then return reply(player, raw, false, 'unknown model ' .. tostring(args[1])) end
    if #m.trims == 0 then return reply(player, raw, false, 'no curated trim for ' .. args[1]) end
    local list = {}
    for _, entry in ipairs(m.trims) do table.insert(list, { label = entry, record = m.record, appearance = entry }) end
    return spawnRow(player, raw, list, args[2])
end, true)

local function paintAll(player, raw, args, secondary, what)
    local ids, why = targets(player, args[1])
    if not ids then return reply(player, raw, false, why) end
    local out = {}
    for _, id in ipairs(ids) do
        local ok, reason = Open77.vehicles.setPaint(id, { primary = MAGIC, secondary = secondary })
        table.insert(out, tostring(id) .. (ok and '' or (' FAILED ' .. tostring(reason))))
    end
    return reply(player, raw, true, what .. ' on ' .. table.concat(out, ', ') .. '; each client logs "vplate77 ..."')
end

-- /vpl.text <id|.|all> <up to 3 chars of 0-9 A-Z space ->   the plate becomes "OP77-<chars>"
RegisterCommand('vpl.text', function(player, args, raw)
    if not player or player <= 0 then return print('vpl.text needs a connected player') end
    if args[2] == nil then args = { '.', args[1] } end
    local text = string.upper(tostring(args[2] or 'LAB'))
    if #text > 3 then return reply(player, raw, false, 'three characters at most: the lab transport is the 3 bytes of the secondary paint') end
    while #text < 3 do text = text .. ' ' end
    local bytes = {}
    for i = 1, 3 do
        local index = ALPHABET:find(text:sub(i, i), 1, true)
        if not index then return reply(player, raw, false, 'character ' .. text:sub(i, i) .. ' is not in ' .. ALPHABET) end
        bytes[i] = index - 1
    end
    return paintAll(player, raw, args, { r = bytes[1], g = bytes[2], b = bytes[3] }, ('plate "OP77-%s"'):format(text))
end, true)

-- /vpl.clear <id|.|all>   back to the factory look
RegisterCommand('vpl.clear', function(player, args, raw)
    if not player or player <= 0 then return print('vpl.clear needs a connected player') end
    return paintAll(player, raw, args, { r = 255, g = 255, b = 255 }, 'plate clear')
end, true)

-- /vpl.state <id|.|all>   no change; each client logs the plate components and their text
RegisterCommand('vpl.state', function(player, args, raw)
    if not player or player <= 0 then return print('vpl.state needs a connected player') end
    return paintAll(player, raw, args, { r = 254, g = 254, b = 254 }, 'plate state')
end, true)

-- /vpl.paint <id|.> <#rrggbb>   a REAL paint: runs vanilla TempDisableUI (all UI widgets off, on 0.6 s later)
RegisterCommand('vpl.paint', function(player, args, raw)
    if not player or player <= 0 then return print('vpl.paint needs a connected player') end
    if args[2] == nil then args = { '.', args[1] } end
    local ids, why = targets(player, args[1])
    if not ids then return reply(player, raw, false, why) end
    local colour = args[2] or '#3050a0'
    if not colour:match('^#%x%x%x%x%x%x$') or colour:lower() == MAGIC then return reply(player, raw, false, 'colour must be #rrggbb and not the magic') end
    local ok, reason = Open77.vehicles.setPaint(ids[1], { primary = colour })
    return reply(player, raw, ok == true, ('paint %s on %s -> %s%s; the plate must survive it'):format(colour, tostring(ids[1]), tostring(ok), ok and '' or (' ' .. tostring(reason))))
end, true)

-- /vpl.app <id|.> <appearance entry>   appearance change: rebuilds the components disabled
RegisterCommand('vpl.app', function(player, args, raw)
    if not player or player <= 0 then return print('vpl.app needs a connected player') end
    if args[2] == nil then args = { '.', args[1] } end
    local ids, why = targets(player, args[1])
    if not ids then return reply(player, raw, false, why) end
    local ok, reason = Open77.vehicles.setAppearance(ids[1], args[2] or '')
    return reply(player, raw, ok == true, ('setAppearance(%s, %q) -> %s%s; the plate is gone until /vpl.text again (the C++ caller will re-apply)'):format(
        tostring(ids[1]), tostring(args[2]), tostring(ok), ok and '' or (' ' .. tostring(reason))))
end, true)

-- /vpl.remove   removes your lab cars
RegisterCommand('vpl.remove', function(player, args, raw)
    if not player or player <= 0 then return end
    return reply(player, raw, true, ('removed %d lab cars'):format(removeAll(player)))
end, true)

AddEventHandler('playerDropped', function()
    local player = tonumber(source)
    if player then removeAll(player) end
end)

print('[vpl] plate lab loaded (design @@DESIGN@@, revision @@REVISION@@): /vpl.car /vpl.trims /vpl.text /vpl.clear /vpl.state /vpl.paint /vpl.app /vpl.remove')
