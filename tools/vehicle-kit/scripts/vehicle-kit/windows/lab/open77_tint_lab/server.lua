-- LAB ONLY. Open77 window tint lab (vehicle customization, route 2): see open77.lua.
-- The level is set with the production native, so what a client shows is exactly what a
-- resource would get. Client side, read the result with the debug bridge (allowlisted):
--   vehicle.tint <vehicleId>        the adapter's level, status, bindings and glass components
--   vehicle.meshapps <cyberId>      any entity's mesh components and the tints their meshes carry
local MODELS = {
    maimai = 'Vehicle.v_standard2_makigai_maimai_player',
    galena = 'Vehicle.v_standard2_thorton_galena_player',
    apollo = 'Vehicle.v_sportbike3_brennan_apollo_player',
    hella = 'Vehicle.v_standard2_archer_hella_player',
    colby = 'Vehicle.v_standard2_thorton_colby_player',
    quartz = 'Vehicle.v_standard2_archer_quartz_player',
    hozuki = 'Vehicle.v_standard2_mizutani_hozuki_player',
    supron = 'Vehicle.v_standard25_mahir_supron_player',
    columbus = 'Vehicle.v_standard25_villefort_columbus_player',
    cortes = 'Vehicle.v_standard2_villefort_cortes_player',
    thrax = 'Vehicle.v_standard2_chevalier_thrax_player',
    bandit = 'Vehicle.v_standard2_archer_bandit_player',
    merrimac = 'Vehicle.v_standard25_thorton_merrimac_player',
    semimaru = 'Vehicle.v_sport1_yaiba_semimaru_player',
    kusanagi = 'Vehicle.v_sportbike1_yaiba_kusanagi_player',
}
local ORDER = { 'maimai', 'galena', 'hella', 'colby', 'quartz', 'hozuki', 'supron', 'columbus',
    'cortes', 'thrax', 'bandit', 'merrimac', 'semimaru', 'apollo', 'kusanagi' }
local cars = {}          -- player -> { vehicle ids }

local function reply(player, raw, ok, text)
    print('[vtint] ' .. text)
    if player and player > 0 then TriggerClientEvent('open77:command:result', player, raw or '', ok == true, text) end
    return ok
end

-- '.' or nothing = the car you sit in, else your last lab car; 'all' = every lab car of yours.
local function targets(player, explicit)
    if explicit == 'all' then
        local list = {}
        for _, id in ipairs(cars[player] or {}) do if Open77.vehicles.get(id) then table.insert(list, id) end end
        if #list == 0 then return nil, 'no lab car: spawn one with /vtint.car' end
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
    return nil, 'no vehicle: spawn one with /vtint.car, or pass its id'
end

-- /vtint.car <model|all>   the dealer model(s), 8 m ahead, in a row
RegisterCommand('vtint.car', function(player, args, raw)
    if not player or player <= 0 then return print('vtint.car needs a connected player') end
    local key = args[1] or 'colby'
    local list = {}
    if key == 'all' then
        for _, k in ipairs(ORDER) do table.insert(list, k) end
    elseif MODELS[key] then
        list = { key }
    else
        return reply(player, raw, false, 'unknown model ' .. tostring(key) .. ' (' .. table.concat(ORDER, ' ') .. ' all)')
    end
    local me = Open77.players.get(player)
    if not me or not me.position then return reply(player, raw, false, 'player position not known yet') end
    local heading = me.heading or 0
    local r = math.rad(heading)
    local fx, fy = -math.sin(r), math.cos(r)
    local rx, ry = math.cos(r), math.sin(r)
    local made = {}
    for i, k in ipairs(list) do
        local side = (i - (#list + 1) / 2) * 3.6
        local id, why = Open77.vehicles.create({ record = MODELS[k],
            position = { x = me.position.x + fx * 8 + rx * side, y = me.position.y + fy * 8 + ry * side, z = me.position.z + 0.25 },
            yaw = heading + 90, bucket = me.bucket, ttlMs = 60 * 60 * 1000 })
        if id then
            cars[player] = cars[player] or {}
            table.insert(cars[player], id)
            table.insert(made, ('%s=%s'):format(k, tostring(id)))
        else
            table.insert(made, ('%s FAILED %s'):format(k, tostring(why)))
        end
    end
    return reply(player, raw, true, 'spawned ' .. table.concat(made, ', ') .. ' (side on)')
end, true)

-- /vtint <id|.|all> <0-3>   or /vtint <0-3> for the car you sit in / your last lab car
RegisterCommand('vtint', function(player, args, raw)
    if args[2] == nil then args = { '.', args[1] } end
    local level = tonumber(args[2])
    if level == nil then return reply(player, raw, false, 'usage: vtint [id|.|all] <0-3>') end
    local ids, why = targets(player, args[1])
    if not ids then return reply(player, raw, false, why) end
    local out = {}
    for _, id in ipairs(ids) do
        local ok, reason = Open77.vehicles.setWindowTint(id, level)
        local visual = Open77.vehicles.getVisual(id)
        table.insert(out, ('%s %s (tint=%s rev=%s)'):format(tostring(id), ok and 'ok' or ('FAILED ' .. tostring(reason)),
            tostring(Open77.vehicles.getWindowTint(id)), visual and tostring(visual.rev) or '?'))
    end
    return reply(player, raw, true, 'setWindowTint ' .. tostring(args[2]) .. ': ' .. table.concat(out, ', '))
end, true)

-- /vtint.get <id|.|all>
RegisterCommand('vtint.get', function(player, args, raw)
    local ids, why = targets(player, args[1])
    if not ids then return reply(player, raw, false, why) end
    local out = {}
    for _, id in ipairs(ids) do
        local level, reason = Open77.vehicles.getWindowTint(id)
        local props = Open77.vehicles.getProperties(id)
        local stored = props and props.visual and props.visual.tint
        table.insert(out, ('%s level=%s properties.visual.tint=%s%s'):format(tostring(id), tostring(level), tostring(stored),
            reason and (' ' .. tostring(reason)) or ''))
    end
    return reply(player, raw, true, table.concat(out, ', '))
end, true)

-- /vtint.remove   every lab car of yours
RegisterCommand('vtint.remove', function(player, args, raw)
    local n = 0
    for _, id in ipairs(cars[player] or {}) do
        if Open77.vehicles.get(id) then Open77.vehicles.remove(id); n = n + 1 end
    end
    cars[player] = {}
    return reply(player, raw, true, 'removed ' .. n .. ' lab car(s)')
end, true)

print('[vtint] window tint lab ready (LAB ONLY): /vtint.car <model|all>, /vtint [id|.|all] <0-3>, /vtint.get, /vtint.remove')
