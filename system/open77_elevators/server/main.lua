-- Reference implementation for authoritative native elevators. The server
-- owns each state and schedule. Clients only project streamed LiftDevice
-- entities and submit bounded button requests.

local flags = Open77.elevators.flags

local function output(source, raw, success, message)
    print(message)
    if source and source > 0 then
        TriggerClientEvent("open77:command:result", source, raw or "", success == true, message)
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
    { command = "/elevator.list", help = "List authoritative elevators.", parameters = {{ name = "bucket", optional = true }} },
    { command = "/elevator.adopt", help = "Adopt a native LiftDevice at its world position.", parameters = {
        { name = "entityHex" }, { name = "x" }, { name = "y" }, { name = "z" },
        { name = "floorCount" }, { name = "bucket", optional = true }, { name = "initialFloor", optional = true }
    } },
    { command = "/elevator.adopt.player", help = "Adopt a LiftDevice at a player's current position.", parameters = {
        { name = "entityHex" }, { name = "playerId" }, { name = "floorCount" }, { name = "initialFloor", optional = true }
    } },
    { command = "/elevator.goto", help = "Move an elevator with native platform motion.", parameters = {
        { name = "id" }, { name = "floor" }, { name = "travelMs", optional = true }
    } },
    { command = "/elevator.teleport", help = "Recover an elevator at an exact floor marker.", parameters = {{ name = "id" }, { name = "floor" }} },
    { command = "/elevator.pause", help = "Pause an active elevator schedule.", parameters = {{ name = "id" }} },
    { command = "/elevator.resume", help = "Resume a paused elevator schedule.", parameters = {{ name = "id" }} },
    { command = "/elevator.power", help = "Enable or disable elevator power.", parameters = {{ name = "id" }, { name = "on|off" }} },
    { command = "/elevator.lock", help = "Lock or unlock player requests.", parameters = {{ name = "id" }, { name = "on|off" }} },
    { command = "/elevator.remove", help = "Release an elevator owned by this resource.", parameters = {{ name = "id" }} },
}

RegisterNetEvent("chat:ready", function() TriggerClientEvent("chat:addSuggestions", source, suggestions) end)

local discoveryWindows = {}

local function finite(value)
    value = tonumber(value)
    if value == nil or value ~= value or value == math.huge or value == -math.huge or math.abs(value) > 1000000 then
        return nil
    end
    return value
end

local function sameEntity(left, right)
    return string.lower(tostring(left or "")) == string.lower(tostring(right or ""))
end

-- Native LiftDevices are world-owned entities and therefore have no Open77 ID
-- until an authenticated client streams one. Discovery only proposes immutable
-- topology. The server validates the player's fresh replicated position,
-- chooses the routing bucket itself and remains the sole state authority.
RegisterNetEvent("open77:elevator:discover", function(engineEntity, x, y, z, floorCount, activeFloor)
    local player = tonumber(source)
    if player == nil or player <= 0 or type(engineEntity) ~= "string" or
        string.match(engineEntity, "^0[xX]%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x$") == nil then return end

    local now = Open77.time.monotonic()
    local window = discoveryWindows[player]
    if window == nil or now - window.started >= 1.0 then
        window = { started = now, count = 0 }
        discoveryWindows[player] = window
    end
    window.count = window.count + 1
    if window.count > 12 then return end

    x, y, z = finite(x), finite(y), finite(z)
    floorCount, activeFloor = tonumber(floorCount), tonumber(activeFloor)
    if x == nil or y == nil or z == nil or floorCount == nil or activeFloor == nil or
        floorCount % 1 ~= 0 or activeFloor % 1 ~= 0 or
        floorCount < 1 or floorCount > 1025 or activeFloor < 0 or activeFloor >= floorCount then return end

    local playerPosition = Open77.players.position(player)
    if playerPosition == nil then return end
    local dx, dy, dz = x - playerPosition.x, y - playerPosition.y, z - playerPosition.z
    if dx * dx + dy * dy + dz * dz > 80.0 * 80.0 then return end

    -- A second observer can report a moving cabin at a slightly different
    -- position. Native hash + server-owned bucket is the durable identity.
    for _, existing in ipairs(Open77.elevators.all(playerPosition.bucket)) do
        if sameEntity(existing.engineEntity, engineEntity) then
            TriggerClientEvent("open77:elevator:discovered", player, existing.engineEntity, existing.id)
            return
        end
    end

    local ok, id, reason = pcall(Open77.elevators.adopt, {
        engineEntity = engineEntity,
        position = { x = x, y = y, z = z },
        bucket = playerPosition.bucket,
        floorCount = floorCount,
        initialFloor = activeFloor,
    })
    if not ok or id == nil then
        print(string.format("elevator discovery rejected player=%s entity=%s reason=%s",
            tostring(player), tostring(engineEntity), tostring(ok and reason or id)))
        return
    end
    print(string.format("elevator auto-adopted id=%s entity=%s player=%s bucket=%s floors=%s active=%s",
        tostring(id), engineEntity, tostring(player), tostring(playerPosition.bucket),
        tostring(floorCount), tostring(activeFloor)))
    TriggerClientEvent("open77:elevator:discovered", player, engineEntity, id)
end)

AddEventHandler("playerDropped", function() discoveryWindows[source] = nil end)

local function printElevators(source, raw, bucket)
    local values = Open77.elevators.all(bucket)
    output(source, raw, true, string.format("elevators (%d):", #values))
    for index, lift in ipairs(values) do
        if index > 100 then return output(source, raw, true, "... output limited to 100 elevators") end
        output(source, raw, true, string.format(
            "id=%d entity=%s bucket=%d floors=%d pos=%.2f,%.2f,%.2f phase=%s floor=%d target=%d flags=%d revision=%d",
            lift.id, lift.engineEntity, lift.bucket, lift.floorCount, lift.x, lift.y, lift.z,
            lift.phase, lift.activeFloor, lift.targetFloor, lift.flags, lift.revision))
    end
end

RegisterCommand("elevator.list", function(source, args, raw)
    if args.n > 1 then return output(source, raw, false, "usage: elevator.list [bucket]") end
    printElevators(source, raw, args[1] and integer(args[1]) or nil)
end, false)

RegisterCommand("elevator.adopt", function(source, args, raw)
    if args.n < 5 or args.n > 7 then
        return output(source, raw, false, "usage: elevator.adopt <entityHex> <x> <y> <z> <floorCount> [bucket] [initialFloor]")
    end
    local id, reason = Open77.elevators.adopt({
        engineEntity = args[1], x = number(args[2]), y = number(args[3]), z = number(args[4]),
        floorCount = integer(args[5]), bucket = args[6] and integer(args[6]) or 0,
        initialFloor = args[7] and integer(args[7]) or 0,
    })
    if not id then return output(source, raw, false, "elevator adoption failed: " .. tostring(reason)) end
    output(source, raw, true, string.format("elevator %d adopted from %s", id, args[1]))
end, true)

RegisterCommand("elevator.adopt.player", function(source, args, raw)
    if args.n < 3 or args.n > 4 then
        return output(source, raw, false, "usage: elevator.adopt.player <entityHex> <playerId> <floorCount> [initialFloor]")
    end
    local playerId = integer(args[2]); local position = Open77.players.position(playerId)
    if not position then return output(source, raw, false, "player has no fresh position snapshot") end
    local id, reason = Open77.elevators.adopt({
        engineEntity = args[1], position = position, bucket = position.bucket, floorCount = integer(args[3]),
        initialFloor = args[4] and integer(args[4]) or 0,
    })
    if not id then return output(source, raw, false, "elevator adoption failed: " .. tostring(reason)) end
    output(source, raw, true, string.format("elevator %d adopted in player %d bucket", id, playerId))
end, true)

RegisterCommand("elevator.goto", function(source, args, raw)
    if args.n < 2 or args.n > 3 then return output(source, raw, false, "usage: elevator.goto <id> <floor> [travelMs]") end
    local ok = Open77.elevators.goTo(integer(args[1]), integer(args[2]), { travelMs = args[3] and integer(args[3]) or 8000 })
    output(source, raw, ok, ok and "elevator movement scheduled" or "elevator movement rejected")
end, true)

RegisterCommand("elevator.teleport", function(source, args, raw)
    if args.n ~= 2 then return output(source, raw, false, "usage: elevator.teleport <id> <floor>") end
    local ok = Open77.elevators.teleport(integer(args[1]), integer(args[2]))
    output(source, raw, ok, ok and "elevator recovered" or "elevator recovery rejected")
end, true)

RegisterCommand("elevator.pause", function(source, args, raw)
    if args.n ~= 1 then return output(source, raw, false, "usage: elevator.pause <id>") end
    local ok = Open77.elevators.pause(integer(args[1])); output(source, raw, ok, ok and "elevator paused" or "elevator pause rejected")
end, true)

RegisterCommand("elevator.resume", function(source, args, raw)
    if args.n ~= 1 then return output(source, raw, false, "usage: elevator.resume <id>") end
    local ok = Open77.elevators.resume(integer(args[1])); output(source, raw, ok, ok and "elevator resumed" or "elevator resume rejected")
end, true)

local function toggleFlag(name, flag)
    RegisterCommand(name, function(source, args, raw)
        if args.n ~= 2 or (args[2] ~= "on" and args[2] ~= "off") then
            return output(source, raw, false, "usage: " .. name .. " <id> <on|off>")
        end
        local id = integer(args[1]); local lift = Open77.elevators.get(id)
        if not lift then return output(source, raw, false, "elevator not found") end
        if args[2] == "on" then lift.flags = lift.flags | flag else lift.flags = lift.flags & (~flag) end
        local ok = Open77.elevators.setFlags(id, lift.flags)
        output(source, raw, ok, ok and "elevator flags updated" or "elevator flags rejected")
    end, true)
end

toggleFlag("elevator.power", flags.powered)
toggleFlag("elevator.lock", flags.locked)

RegisterCommand("elevator.remove", function(source, args, raw)
    if args.n ~= 1 then return output(source, raw, false, "usage: elevator.remove <id>") end
    local id = integer(args[1]); local ok = Open77.elevators.remove(id)
    output(source, raw, ok, ok and string.format("elevator %d removed", id) or "elevator not found or not owned")
end, true)

AddEventHandler("onElevatorStateChanged", function(id, revision, bucket, phase, activeFloor, targetFloor)
    print(string.format("elevator state id=%s revision=%s bucket=%s phase=%s floor=%s target=%s",
        id, revision, bucket, phase, activeFloor, targetFloor))
end)

AddEventHandler("onElevatorRemoved", function(id, revision, reason)
    print(string.format("elevator removed id=%s revision=%s reason=%s", id, revision, reason))
end)

print("server elevator authority ready; use elevator.list or elevator.adopt")
