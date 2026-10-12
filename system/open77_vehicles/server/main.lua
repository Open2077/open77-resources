-- Reference implementation for server-owned network vehicles.
-- Clients receive streamed projections and may only request a short physics
-- lease by actually becoming the local driver; all durable mutations stay here.

local DEFAULT_MODEL = "Vehicle.v_standard2_archer_hella_player"

local function output(source, raw, success, text)
    print(text)
    if source and source > 0 then
        TriggerClientEvent("open77:command:result", source, raw or "", success == true, text)
    end
end

local function number(value)
    local parsed = tonumber(value)
    if parsed == nil then error("number expected: " .. tostring(value), 0) end
    return parsed
end

local function integer(value)
    local parsed = number(value)
    if parsed % 1 ~= 0 then error("integer expected: " .. tostring(value), 0) end
    return parsed
end

local suggestions = {
    { command = "/vehicle.list", help = "List server-owned network vehicles.", parameters = {{ name = "bucket", optional = true }} },
    { command = "/vehicle.create", help = "Create a network vehicle at world coordinates.", parameters = {
        { name = "x" }, { name = "y" }, { name = "z" }, { name = "yaw", optional = true },
        { name = "model", optional = true }, { name = "bucket", optional = true }
    } },
    { command = "/vehicle.create.player", help = "Create a network vehicle beside a player.", parameters = {
        { name = "playerId" }, { name = "model", optional = true }
    } },
    { command = "/vehicle.remove", help = "Remove a canonical network vehicle.", parameters = {{ name = "id" }} },
    { command = "/vehicle.engine", help = "Set a vehicle engine state.", parameters = {{ name = "id" }, { name = "on|off" }} },
    { command = "/vehicle.lock", help = "Set a vehicle lock state.", parameters = {{ name = "id" }, { name = "on|off" }} },
    { command = "/vehicle.horn", help = "Sound a synchronized vehicle horn.", parameters = {
        { name = "id" }, { name = "durationMs", optional = true }
    } },
    { command = "/vehicle.health", help = "Set normalized vehicle health.", parameters = {{ name = "id" }, { name = "0..1" }} },
    { command = "/vehicle.glass.break", help = "Break a vehicle glass record by zero-based index.", parameters = {{ name = "id" }, { name = "glassIndex" }} },
    { command = "/vehicle.glass.repair", help = "Repair one glass record, or every glass with 'all'.", parameters = {{ name = "id" }, { name = "glassIndex|all" }} },
    { command = "/vehicle.repair", help = "Repair canonical vehicle damage.", parameters = {{ name = "id" }, { name = "glass|body|lights|tires|visual|mechanical|full", optional = true }} },
    { command = "/vehicle.paint", help = "Set primary and secondary RGB paint.", parameters = {
        { name = "id" }, { name = "r" }, { name = "g" }, { name = "b" },
        { name = "r2", optional = true }, { name = "g2", optional = true }, { name = "b2", optional = true }
    } },
    { command = "/vehicle.paint.reset", help = "Restore a vehicle's original paint.", parameters = {{ name = "id" }} },
    { command = "/vehicle.warp", help = "Force a player into a canonical vehicle seat.", parameters = {
        { name = "playerId" }, { name = "vehicleId" }, { name = "seat", optional = true },
        { name = "lockExit", optional = true }
    } },
    { command = "/vehicle.out", help = "Force a player out of their vehicle.", parameters = {
        { name = "playerId" }, { name = "vehicleId", optional = true }
    } },
    { command = "/vehicle.exitlock", help = "Allow or prevent a player from exiting.", parameters = {
        { name = "playerId" }, { name = "on|off" }, { name = "vehicleId", optional = true }
    } },
    { command = "/vehicle.seat", help = "Show a player's canonical vehicle seat.", parameters = {
        { name = "playerId" }
    } },
    { command = "/vehicle.probe", help = "Print the target client's replicated vehicle state.", parameters = {
        { name = "playerId" }
    } },
}

RegisterNetEvent("chat:ready", function() TriggerClientEvent("chat:addSuggestions", source, suggestions) end)

local function list(source, raw, bucket)
    local vehicles = Open77.vehicles.all(bucket)
    output(source, raw, true, string.format("vehicles (%d):", #vehicles))
    for index, vehicle in ipairs(vehicles) do
        if index > 100 then return output(source, raw, true, "... output limited to 100 vehicles") end
        local seats = {}
        for _, occupant in ipairs(vehicle.occupants or {}) do
            seats[#seats + 1] = string.format("%s:%d", occupant.seat, occupant.playerId)
        end
        -- The age of the last ACCEPTED motion sample, on the same
        -- GetGameTimer() clock as everything else here. `none` means no sample
        -- has ever been accepted (or the stamp was cleared with the authority);
        -- it is never printed as 0, because a sample accepted this very tick is
        -- genuinely 0 ms old and the two must not read the same.
        local age = vehicle.motionAgeMs
        -- The AI driving task, through the existing accessor rather than a new
        -- one: `state` is a registry lookup and returns nothing when the car
        -- has no AI job. A refusal carries a reason string, and that is printed
        -- as the reason -- reporting a refusal as `none` would read as "no AI
        -- task" and turn a denied diagnostic into a false negative.
        local task, taskReason = Open77.vehicles.ai.state(vehicle.id)
        local ai = "none"
        if task ~= nil then
            ai = string.format("%s/%s", tostring(task.mode), tostring(task.status))
        elseif taskReason ~= nil then
            ai = tostring(taskReason)
        end
        output(source, raw, true, string.format(
            "id=%d model=%s bucket=%d pos=%.2f,%.2f,%.2f speed=%.2f motionAgeMs=%s health=%.2f owner=%d epoch=%d ai=%s occupants=[%s]",
            vehicle.id, vehicle.record, vehicle.bucket, vehicle.x, vehicle.y, vehicle.z,
            vehicle.speed, age == nil and "none" or string.format("%.0f", age),
            vehicle.health, vehicle.physicsOwner, vehicle.authorityEpoch, ai, table.concat(seats, ",")))
    end
end

RegisterCommand("vehicle.list", function(source, args, raw)
    if args.n > 1 then return output(source, raw, false, "usage: vehicle.list [bucket]") end
    list(source, raw, args[1] and integer(args[1]) or nil)
end, false)

RegisterCommand("vehicle.create", function(source, args, raw)
    if args.n < 3 or args.n > 6 then return output(source, raw, false, "usage: vehicle.create <x> <y> <z> [yaw] [model] [bucket]") end
    local id, reason = Open77.vehicles.create({
        record = args[5] or DEFAULT_MODEL,
        position = { x = number(args[1]), y = number(args[2]), z = number(args[3]) },
        yaw = args[4] and number(args[4]) or 0,
        bucket = args[6] and integer(args[6]) or 0,
    })
    if id == nil then return output(source, raw, false, "vehicle create failed: " .. tostring(reason)) end
    output(source, raw, true, string.format("vehicle %d created", id))
end, true)

RegisterCommand("vehicle.create.player", function(source, args, raw)
    if args.n < 1 or args.n > 2 then return output(source, raw, false, "usage: vehicle.create.player <playerId> [model]") end
    local playerId = integer(args[1])
    local position = Open77.players.position(playerId)
    if position == nil then return output(source, raw, false, "player has no fresh position snapshot") end
    local id, reason = Open77.vehicles.create({
        record = args[2] or DEFAULT_MODEL,
        position = { x = position.x + 3.0, y = position.y, z = position.z + 0.25 },
        bucket = position.bucket,
    })
    if id == nil then return output(source, raw, false, "vehicle create failed: " .. tostring(reason)) end
    output(source, raw, true, string.format("vehicle %d created beside player %d", id, playerId))
end, true)

RegisterCommand("vehicle.remove", function(source, args, raw)
    if args.n ~= 1 then return output(source, raw, false, "usage: vehicle.remove <id>") end
    local id = integer(args[1]); local ok = Open77.vehicles.remove(id)
    output(source, raw, ok, ok and string.format("vehicle %d removed", id) or "vehicle not found")
end, true)

local function toggle(flag, name)
    return function(source, args, raw)
        if args.n ~= 2 or (args[2] ~= "on" and args[2] ~= "off") then return output(source, raw, false, "usage: " .. name .. " <id> <on|off>") end
        local id = integer(args[1]); local vehicle = Open77.vehicles.get(id)
        if not vehicle then return output(source, raw, false, "vehicle not found") end
        local enabled = args[2] == "on"
        if enabled then vehicle.flags = vehicle.flags | flag else vehicle.flags = vehicle.flags & (~flag) end
        local ok = Open77.vehicles.update(id, { flags = vehicle.flags })
        output(source, raw, ok, ok and "vehicle state updated" or "vehicle state rejected")
    end
end

RegisterCommand("vehicle.engine", toggle(Open77.vehicles.flags.engineOn, "vehicle.engine"), true)
RegisterCommand("vehicle.lock", function(source, args, raw)
    if args.n ~= 2 or (args[2] ~= "on" and args[2] ~= "off") then
        return output(source, raw, false, "usage: vehicle.lock <id> <on|off>")
    end
    local id = integer(args[1])
    local ok, reason = Open77.vehicles.setLocked(id, args[2] == "on")
    output(source, raw, ok == true,
        ok and (args[2] == "on" and "vehicle locked" or "vehicle unlocked") or tostring(reason))
end, true)

RegisterCommand("vehicle.horn", function(source, args, raw)
    if args.n < 1 or args.n > 2 then
        return output(source, raw, false, "usage: vehicle.horn <id> [durationMs]")
    end
    local duration = args[2] and integer(args[2]) or 250
    local ok, reason = Open77.vehicles.triggerHorn(integer(args[1]), duration)
    output(source, raw, ok == true, ok and "vehicle horn triggered" or tostring(reason))
end, true)

RegisterCommand("vehicle.health", function(source, args, raw)
    if args.n ~= 2 then return output(source, raw, false, "usage: vehicle.health <id> <0..1>") end
    local ok = Open77.vehicles.update(integer(args[1]), { health = number(args[2]) })
    output(source, raw, ok, ok and "vehicle health updated" or "vehicle health rejected")
end, true)

RegisterCommand("vehicle.damage.dump", function(source, args, raw)
    if args.n ~= 1 then return output(source, raw, false, "usage: vehicle.damage.dump <id>") end
    local vehicle = Open77.vehicles.get(integer(args[1]))
    if not vehicle then return output(source, raw, false, "vehicle not found") end
    local body = {}
    for index, value in ipairs(vehicle.bodyDamage or {}) do
        if math.abs(value) > 0.0005 then
            body[#body + 1] = string.format("%d:%.3f", index - 1, value)
        end
    end
    output(source, raw, true, string.format(
        "vehicle=%s health=%.3f glass=0x%X lights=0x%X tires=0x%X body=[%s]",
        tostring(vehicle.id), vehicle.health, vehicle.brokenGlass, vehicle.brokenLights,
        vehicle.tires, table.concat(body, ",")))
end, false)

RegisterCommand("vehicle.glass.break", function(source, args, raw)
    if args.n ~= 2 then return output(source, raw, false, "usage: vehicle.glass.break <id> <glassIndex>") end
    local ok = Open77.vehicles.breakGlass(integer(args[1]), integer(args[2]))
    output(source, raw, ok, ok and "vehicle glass broken" or "vehicle damage rejected")
end, true)

RegisterCommand("vehicle.glass.repair", function(source, args, raw)
    if args.n ~= 2 then return output(source, raw, false, "usage: vehicle.glass.repair <id> <glassIndex|all>") end
    local id = integer(args[1])
    local ok = args[2] == "all" and Open77.vehicles.repairAllGlass(id)
        or Open77.vehicles.repairGlass(id, integer(args[2]))
    output(source, raw, ok, ok and "vehicle glass repaired" or "vehicle repair rejected")
end, true)

RegisterCommand("vehicle.repair", function(source, args, raw)
    if args.n < 1 or args.n > 2 then return output(source, raw, false,
        "usage: vehicle.repair <id> [glass|body|lights|tires|visual|mechanical|full]") end
    local ok = Open77.vehicles.repair(integer(args[1]), args[2] or "full")
    output(source, raw, ok, ok and "vehicle repaired" or "vehicle repair rejected")
end, true)

RegisterCommand("vehicle.paint", function(source, args, raw)
    if args.n ~= 4 and args.n ~= 7 then return output(source, raw, false, "usage: vehicle.paint <id> <r> <g> <b> [r2 g2 b2]") end
    local primary = { r = integer(args[2]), g = integer(args[3]), b = integer(args[4]) }
    local secondary = args.n == 7 and { r = integer(args[5]), g = integer(args[6]), b = integer(args[7]) } or primary
    local ok = Open77.vehicles.setPaint(integer(args[1]), { primary = primary, secondary = secondary })
    output(source, raw, ok, ok and "vehicle paint updated" or "vehicle paint rejected")
end, true)

RegisterCommand("vehicle.paint.reset", function(source, args, raw)
    if args.n ~= 1 then return output(source, raw, false, "usage: vehicle.paint.reset <id>") end
    local ok = Open77.vehicles.resetPaint(integer(args[1]))
    output(source, raw, ok, ok and "vehicle paint reset" or "vehicle paint reset rejected")
end, true)

local function enabled(value)
    value = tostring(value or ""):lower()
    if value == "on" or value == "true" or value == "1" then return true end
    if value == "off" or value == "false" or value == "0" then return false end
    error("boolean expected: on|off", 0)
end

RegisterCommand("vehicle.warp", function(source, args, raw)
    if args.n < 2 or args.n > 4 then
        return output(source, raw, false, "usage: vehicle.warp <playerId> <vehicleId> [seat] [lockExit]")
    end
    local options = { moveBucket = true, exitLocked = args[4] ~= nil and enabled(args[4]) or false }
    local ok, reason = Open77.vehicles.warpPlayerIntoVehicle(
        integer(args[1]), integer(args[2]), args[3] or "driver", options)
    output(source, raw, ok == true, ok and "player assigned to vehicle seat" or tostring(reason))
end, true)

RegisterCommand("vehicle.out", function(source, args, raw)
    if args.n < 1 or args.n > 2 then
        return output(source, raw, false, "usage: vehicle.out <playerId> [vehicleId]")
    end
    local ok, reason = Open77.vehicles.forcePlayerOutOfVehicle(
        integer(args[1]), args[2] and integer(args[2]) or nil)
    output(source, raw, ok == true, ok and "player forced out of vehicle" or tostring(reason))
end, true)

RegisterCommand("vehicle.exitlock", function(source, args, raw)
    if args.n < 2 or args.n > 3 then
        return output(source, raw, false, "usage: vehicle.exitlock <playerId> <on|off> [vehicleId]")
    end
    local ok, reason = Open77.vehicles.setPlayerExitLocked(
        integer(args[1]), enabled(args[2]), args[3] and integer(args[3]) or nil)
    output(source, raw, ok == true, ok and "player exit policy updated" or tostring(reason))
end, true)

RegisterCommand("vehicle.seat", function(source, args, raw)
    if args.n ~= 1 then return output(source, raw, false, "usage: vehicle.seat <playerId>") end
    local seat = Open77.vehicles.getPlayerSeat(integer(args[1]))
    if seat == nil then return output(source, raw, true, "player is not assigned to a vehicle") end
    output(source, raw, true, ("vehicle=%s seat=%s flags=%s locked=%s"):format(
        tostring(seat.vehicleId), tostring(seat.seat), tostring(seat.flags),
        tostring(Open77.vehicles.isPlayerExitLocked(integer(args[1])))))
end, true)

RegisterCommand("vehicle.probe", function(source, args, raw)
    if args.n ~= 1 then return output(source, raw, false, "usage: vehicle.probe <playerId>") end
    local playerId = integer(args[1])
    local ok, reason = TriggerClientEvent("open77:vehicles:probe", playerId)
    output(source, raw, ok == true, ok and "client vehicle probe requested" or tostring(reason))
end, true)

-- Same restricted diagnostic path as vehicle.probe: an admin/console requests
-- a read-only client snapshot, without weakening the active-session bridge guard.
RegisterCommand("vehicle.weapons.probe", function(source, args, raw)
    if args.n ~= 1 then return output(source, raw, false, "usage: vehicle.weapons.probe <playerId>") end
    local playerId = integer(args[1])
    local ok, reason = TriggerClientEvent("open77:vehicles:weapons:probe", playerId)
    output(source, raw, ok == true, ok and "client vehicle weapon probe requested" or tostring(reason))
end, true)

AddEventHandler("onVehicleAuthorityChanged", function(id, owner, epoch, reason)
    print(string.format("authority vehicle=%s owner=%s epoch=%s reason=%s", id, owner, epoch, reason))
end)

AddEventHandler("onVehicleOccupancyChanged", function(id, revision)
    local vehicle = Open77.vehicles.get(tonumber(id))
    if not vehicle then return end
    for _, occupant in ipairs(vehicle.occupants or {}) do
        print(string.format("occupancy vehicle=%s revision=%s player=%s seat=%s",
            id, revision, occupant.playerId, occupant.seat))
    end
end)

AddEventHandler("onVehicleDamageChanged", function(id, revision)
    local vehicle = Open77.vehicles.get(tonumber(id))
    if not vehicle then return end
    local body = {}
    for index, value in ipairs(vehicle.bodyDamage or {}) do
        if math.abs(value) > 0.0005 then
            body[#body + 1] = string.format("%d:%.3f", index - 1, value)
        end
    end
    print(string.format("damage vehicle=%s revision=%s health=%.3f glass=0x%X lights=0x%X tires=0x%X body=[%s]",
        id, revision, vehicle.health, vehicle.brokenGlass, vehicle.brokenLights, vehicle.tires,
        table.concat(body, ",")))
end)

print("server vehicle authority ready; paint and damage APIs enabled")
