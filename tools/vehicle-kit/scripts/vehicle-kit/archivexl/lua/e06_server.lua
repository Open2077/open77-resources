-- E0.6 lab (vehicle customization): ArchiveXL-added appearances on a vanilla Archer Hella.
-- Copied by scripts/vehicle-kit/archivexl/build-axl-pack.ps1 (revision @@REVISION@@). LAB ONLY.
-- The preload_mod of this resource adds, to the Hella player entity, the appearances
-- listed in APPEARANCES. setAppearance carries the name to every viewer unchanged; each
-- client applies it with ScheduleAppearanceChange, so what a viewer sees is the test.
-- Every command is restricted: grant the lab account the ACL entries command.vapp.<name>
-- (command.vapp.car, command.vapp.test, ...).
local RECORD = 'Vehicle.v_standard2_archer_hella_player'
local APPEARANCES = {
    { name = '', expect = 'the record default (factory player_01)' },
    { name = 'open77_e06_a', expect = 'factory look + junk solar panel on the roof' },
    { name = 'open77_e06_dyn', expect = 'factory look (an ordinary entry: the dynamic tag is disabled in this pack, see the README)' },
    { name = 'open77_e06_dyn!a', expect = 'NEGATIVE CONTROL: no .ent entry, expect NO change and no crash; note what the car shows' },
    { name = 'open77_e06_parts', expect = 'solar panel merged from a part .ent (AppearanceParts)' },
}
local CYCLE_STEP_MS = 8000
local cars = {}       -- [player] = vehicle id of the lab car
local cycles = {}     -- [player] = cycle generation, bumped to stop a running cycle

local function reply(player, raw, ok, text)
    print('[vapp] ' .. text)
    if player and player > 0 then TriggerClientEvent('open77:command:result', player, raw or '', ok == true, text) end
    return ok
end

local function expectation(name)
    for _, a in ipairs(APPEARANCES) do if a.name == name then return a.expect end end
    return 'not one of the lab names: an unknown variant is a no-op on every viewer'
end

-- "default", "-" or "" mean the record default; anything else is passed through verbatim.
local function appearanceArg(text)
    if text == nil or text == '' or text == 'default' or text == '-' then return '' end
    return text
end

-- An explicit id, else the car the player sits in, else this player's lab car.
local function vehicleFor(player, explicit)
    if explicit and explicit ~= '.' then
        local id = tonumber(explicit)
        if id and Open77.vehicles.get(id) then return id end
        return nil, 'no vehicle ' .. tostring(explicit)
    end
    local seat = Open77.vehicles.getPlayerSeat(player)
    if seat and seat.vehicleId and Open77.vehicles.get(seat.vehicleId) then return seat.vehicleId end
    if cars[player] and Open77.vehicles.get(cars[player]) then return cars[player] end
    return nil, 'no vehicle: spawn one with /vapp.car, or pass its id'
end

local function setAndReport(player, raw, id, name)
    local ok, why = Open77.vehicles.setAppearance(id, name)
    local now = Open77.vehicles.getAppearance(id)
    return reply(player, raw, ok == true, ('setAppearance(%s, %q) -> %s%s; server now holds %q; expect: %s'):format(
        tostring(id), name, tostring(ok), ok and '' or (' ' .. tostring(why)), tostring(now), expectation(name)))
end

-- /vapp.car [appearance]   spawns a Hella 6 m ahead, side-on, optionally born wearing <appearance>
RegisterCommand('vapp.car', function(player, args, raw)
    if not player or player <= 0 then return print('vapp.car needs a connected player') end
    local me = Open77.players.get(player)
    if not me or not me.position then return reply(player, raw, false, 'player position not known yet') end
    local heading = me.heading or 0
    local r = math.rad(heading)
    -- Yaw 0 faces +Y and turns counter-clockwise: forward is (-sin, cos).
    local position = { x = me.position.x - math.sin(r) * 6, y = me.position.y + math.cos(r) * 6, z = me.position.z + 0.25 }
    local definition = { record = RECORD, position = position, yaw = heading + 90, bucket = me.bucket, ttlMs = 60 * 60 * 1000 }
    local appearance = appearanceArg(args[1])
    if appearance ~= '' then definition.appearance = appearance end
    if cars[player] and Open77.vehicles.get(cars[player]) then Open77.vehicles.remove(cars[player]) end
    local id, why = Open77.vehicles.create(definition)
    if not id then return reply(player, raw, false, 'vehicles.create: ' .. tostring(why)) end
    cars[player] = id
    return reply(player, raw, true, ('lab Hella %s spawned%s; server holds %q'):format(tostring(id),
        appearance ~= '' and (' born wearing ' .. appearance) or '', tostring(Open77.vehicles.getAppearance(id))))
end, true)

-- /vapp.test <vehicleId|.> <appearance|default>   '.' = the car you sit in, else your lab car
RegisterCommand('vapp.test', function(player, args, raw)
    if not player or player <= 0 then return print('vapp.test needs a connected player') end
    if args[2] == nil and args[1] ~= nil and not tonumber(args[1]) and args[1] ~= '.' then args = { '.', args[1] } end
    local id, why = vehicleFor(player, args[1])
    if not id then return reply(player, raw, false, why) end
    return setAndReport(player, raw, id, appearanceArg(args[2]))
end, true)

-- /vapp.get [vehicleId]
RegisterCommand('vapp.get', function(player, args, raw)
    if not player or player <= 0 then return print('vapp.get needs a connected player') end
    local id, why = vehicleFor(player, args[1])
    if not id then return reply(player, raw, false, why) end
    local name = Open77.vehicles.getAppearance(id)
    return reply(player, raw, true, ('vehicle %s wears %q (%s)'):format(tostring(id), tostring(name), expectation(name or '')))
end, true)

-- /vapp.list   the names this pack defines and what each should look like
RegisterCommand('vapp.list', function(player, args, raw)
    local lines = {}
    for i, a in ipairs(APPEARANCES) do lines[#lines + 1] = ('%d. %q = %s'):format(i, a.name, a.expect) end
    return reply(player, raw, true, table.concat(lines, ' | '))
end, true)

-- /vapp.cycle [vehicleId] [stepMs]   walks the whole list on one car, one step every 8 s
-- /vapp.cycle stop
RegisterCommand('vapp.cycle', function(player, args, raw)
    if not player or player <= 0 then return print('vapp.cycle needs a connected player') end
    cycles[player] = (cycles[player] or 0) + 1
    if args[1] == 'stop' then return reply(player, raw, true, 'cycle stopped') end
    local id, why = vehicleFor(player, args[1])
    if not id then return reply(player, raw, false, why) end
    local step = math.max(3000, tonumber(args[2]) or CYCLE_STEP_MS)
    local generation = cycles[player]
    CreateThread(function()
        for i, a in ipairs(APPEARANCES) do
            if cycles[player] ~= generation or not Open77.vehicles.get(id) then return end
            reply(player, raw, true, ('[%d/%d]'):format(i, #APPEARANCES))
            setAndReport(player, raw, id, a.name)
            Wait(step)
        end
        reply(player, raw, true, 'cycle done; the car keeps the last appearance')
    end)
    return reply(player, raw, true, ('cycling %d appearances on vehicle %s, %d ms each'):format(#APPEARANCES, tostring(id), step))
end, true)

-- /vapp.clear   removes your lab car (never a car this resource did not create)
RegisterCommand('vapp.clear', function(player, args, raw)
    if not player or player <= 0 then return end
    cycles[player] = (cycles[player] or 0) + 1
    local id = cars[player]
    if id and Open77.vehicles.get(id) then Open77.vehicles.remove(id) end
    cars[player] = nil
    return reply(player, raw, true, id and ('removed lab car ' .. tostring(id)) or 'no lab car')
end, true)

AddEventHandler('playerDropped', function()
    local player = tonumber(source)
    if not player then return end
    cycles[player] = (cycles[player] or 0) + 1
    if cars[player] and Open77.vehicles.get(cars[player]) then Open77.vehicles.remove(cars[player]) end
    cars[player] = nil
end)

print('[vapp] E0.6 lab loaded (revision @@REVISION@@): /vapp.car /vapp.test /vapp.get /vapp.list /vapp.cycle /vapp.clear')
