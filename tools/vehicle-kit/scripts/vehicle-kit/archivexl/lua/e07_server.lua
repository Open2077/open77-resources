-- E0.7 lab (vehicle customization), route W: a text widget over the Galena rear plate.
-- Copied by scripts/vehicle-kit/archivexl/build-axl-pack.ps1 (revision @@REVISION@@). LAB ONLY.
-- The preload_mod adds four appearances to the Galena player entity; each is the factory
-- player_01 plus an ArchiveXL-added screen quad (and, for three of them, a
-- WorldWidgetComponent drawing a vanilla .inkwidget on it) over the rear plate.
-- Setting the TEXT needs the lab REDscript Open77VehiclePlateLab.reds on every client
-- (installed by hand, see the README): it intercepts the magic paint #040506 and reads the
-- three secondary bytes as characters. Paint replicates, so every viewer, a late joiner
-- included, receives the same text. Every command is restricted: grant the lab account the
-- ACL entries command.vplate.<name> (command.vplate.car, command.vplate.text, ...).
local RECORD = 'Vehicle.v_standard2_thorton_galena_player'
local VARIANTS = {
    plate = { appearance = 'open77_e07_plate', expect = 'street-sign widget on the rear plate, text readable from behind' },
    flip = { appearance = 'open77_e07_plate_flip', expect = 'same widget, quad turned 180 deg: predicted to read mirrored from behind (orientation control)' },
    lcd = { appearance = 'open77_e07_plate_lcd', expect = 'LCD 10x1 widget, a thin text band on the rear plate' },
    quad = { appearance = 'open77_e07_quad', expect = 'the bare screen quad over the plate, no widget (placement control)' },
    factory = { appearance = '', expect = 'the factory Galena, vanilla plate' },
}
local ORDER = { 'quad', 'plate', 'flip', 'lcd', 'factory' }
-- Must match ALPHABET in Open77VehiclePlateLab.reds (index = secondary colour byte).
local ALPHABET = '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ -'
local MAGIC = '#040506'
local cars = {}

local function reply(player, raw, ok, text)
    print('[vplate] ' .. text)
    if player and player > 0 then TriggerClientEvent('open77:command:result', player, raw or '', ok == true, text) end
    return ok
end

local function variantOf(text)
    if text == nil or text == '' then return 'plate', VARIANTS.plate end
    if VARIANTS[text] then return text, VARIANTS[text] end
    for key, v in pairs(VARIANTS) do if v.appearance == text then return key, v end end
    return nil
end

local function vehicleFor(player, explicit)
    if explicit and explicit ~= '.' then
        local id = tonumber(explicit)
        if id and Open77.vehicles.get(id) then return id end
        return nil, 'no vehicle ' .. tostring(explicit)
    end
    local seat = Open77.vehicles.getPlayerSeat(player)
    if seat and seat.vehicleId and Open77.vehicles.get(seat.vehicleId) then return seat.vehicleId end
    if cars[player] and Open77.vehicles.get(cars[player]) then return cars[player] end
    return nil, 'no vehicle: spawn one with /vplate.car, or pass its id'
end

-- /vplate.car [plate|flip|lcd|quad|factory]   a Galena 7 m ahead, facing away: you see its rear
RegisterCommand('vplate.car', function(player, args, raw)
    if not player or player <= 0 then return print('vplate.car needs a connected player') end
    local key, variant = variantOf(args[1])
    if not key then return reply(player, raw, false, 'unknown variant ' .. tostring(args[1]) .. ' (plate|flip|lcd|quad|factory)') end
    local me = Open77.players.get(player)
    if not me or not me.position then return reply(player, raw, false, 'player position not known yet') end
    local heading = me.heading or 0
    local r = math.rad(heading)
    local position = { x = me.position.x - math.sin(r) * 7, y = me.position.y + math.cos(r) * 7, z = me.position.z + 0.25 }
    local definition = { record = RECORD, position = position, yaw = heading, bucket = me.bucket, ttlMs = 60 * 60 * 1000 }
    if variant.appearance ~= '' then definition.appearance = variant.appearance end
    if cars[player] and Open77.vehicles.get(cars[player]) then Open77.vehicles.remove(cars[player]) end
    local id, why = Open77.vehicles.create(definition)
    if not id then return reply(player, raw, false, 'vehicles.create: ' .. tostring(why)) end
    cars[player] = id
    return reply(player, raw, true, ('lab Galena %s spawned as %s (%q); expect: %s'):format(
        tostring(id), key, tostring(Open77.vehicles.getAppearance(id)), variant.expect))
end, true)

-- /vplate.app <vehicleId|.> <plate|flip|lcd|quad|factory|appearance name>
RegisterCommand('vplate.app', function(player, args, raw)
    if not player or player <= 0 then return print('vplate.app needs a connected player') end
    if args[2] == nil then args = { '.', args[1] } end
    local id, why = vehicleFor(player, args[1])
    if not id then return reply(player, raw, false, why) end
    local key, variant = variantOf(args[2])
    local name = variant and variant.appearance or args[2]
    local ok, reason = Open77.vehicles.setAppearance(id, name)
    return reply(player, raw, ok == true, ('setAppearance(%s, %q) -> %s%s; server holds %q; expect: %s'):format(
        tostring(id), name, tostring(ok), ok and '' or (' ' .. tostring(reason)),
        tostring(Open77.vehicles.getAppearance(id)), variant and variant.expect or 'not a lab name'))
end, true)

-- /vplate.text <vehicleId|.> <up to 3 chars of 0-9 A-Z space ->   plate becomes "OP77-<chars>"
RegisterCommand('vplate.text', function(player, args, raw)
    if not player or player <= 0 then return print('vplate.text needs a connected player') end
    if args[2] == nil then args = { '.', args[1] } end
    local id, why = vehicleFor(player, args[1])
    if not id then return reply(player, raw, false, why) end
    local text = string.upper(tostring(args[2] or 'LAB'))
    if #text > 3 then return reply(player, raw, false, 'three characters at most: the transport is the 3 bytes of the secondary paint') end
    while #text < 3 do text = text .. ' ' end
    local bytes = {}
    for i = 1, 3 do
        local index = ALPHABET:find(text:sub(i, i), 1, true)
        if not index then return reply(player, raw, false, 'character ' .. text:sub(i, i) .. ' is not in ' .. ALPHABET) end
        bytes[i] = index - 1
    end
    local ok, reason = Open77.vehicles.setPaint(id, { primary = MAGIC, secondary = { r = bytes[1], g = bytes[2], b = bytes[3] } })
    return reply(player, raw, ok == true, ('plate text %q on vehicle %s via paint %s + (%d,%d,%d) -> %s%s; every client with the lab REDscript logs "vplate ..."'):format(
        'OP77-' .. text, tostring(id), MAGIC, bytes[1], bytes[2], bytes[3], tostring(ok), ok and '' or (' ' .. tostring(reason))))
end, true)

-- /vplate.describe <vehicleId|.>   no text change; each client logs the widget tree it got
RegisterCommand('vplate.describe', function(player, args, raw)
    if not player or player <= 0 then return print('vplate.describe needs a connected player') end
    local id, why = vehicleFor(player, args[1])
    if not id then return reply(player, raw, false, why) end
    local ok, reason = Open77.vehicles.setPaint(id, { primary = MAGIC, secondary = { r = 255, g = 255, b = 255 } })
    return reply(player, raw, ok == true, ('describe request on vehicle %s -> %s%s; read "vplate tree" in each client log'):format(
        tostring(id), tostring(ok), ok and '' or (' ' .. tostring(reason))))
end, true)

-- /vplate.cycle [vehicleId]   quad, plate, flip, lcd, factory, 10 s each
RegisterCommand('vplate.cycle', function(player, args, raw)
    if not player or player <= 0 then return print('vplate.cycle needs a connected player') end
    local id, why = vehicleFor(player, args[1])
    if not id then return reply(player, raw, false, why) end
    CreateThread(function()
        for i, key in ipairs(ORDER) do
            if not Open77.vehicles.get(id) then return end
            local ok, reason = Open77.vehicles.setAppearance(id, VARIANTS[key].appearance)
            reply(player, raw, ok == true, ('[%d/%d] %s -> %s%s; expect: %s'):format(i, #ORDER, key, tostring(ok),
                ok and '' or (' ' .. tostring(reason)), VARIANTS[key].expect))
            Wait(10000)
        end
    end)
    return reply(player, raw, true, 'cycling ' .. table.concat(ORDER, ', ') .. ' on vehicle ' .. tostring(id))
end, true)

-- /vplate.clear   removes your lab car
RegisterCommand('vplate.clear', function(player, args, raw)
    if not player or player <= 0 then return end
    local id = cars[player]
    if id and Open77.vehicles.get(id) then Open77.vehicles.remove(id) end
    cars[player] = nil
    return reply(player, raw, true, id and ('removed lab car ' .. tostring(id)) or 'no lab car')
end, true)

AddEventHandler('playerDropped', function()
    local player = tonumber(source)
    if not player then return end
    if cars[player] and Open77.vehicles.get(cars[player]) then Open77.vehicles.remove(cars[player]) end
    cars[player] = nil
end)

print('[vplate] E0.7 lab loaded (revision @@REVISION@@): /vplate.car /vplate.app /vplate.text /vplate.describe /vplate.cycle /vplate.clear')
