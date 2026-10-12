-- Server authority and administration for Open77 world props.
--
-- Open77.props is injected by the dedicated-server runtime. This resource owns
-- only the props created by its commands; gameplay resources can use the same
-- API and retain ownership of their own props.

local DEFAULT_NEAR_RADIUS = 15.0
local MAX_LISTED = 100

local function output(source, raw, success, text)
    print(text)
    if source ~= nil and source > 0 then
        TriggerClientEvent("open77:command:result", source, raw or "", success == true, text)
    end
end

local CHAT_SUGGESTIONS = {
    { command = "/prop.create", help = "Create a world prop at world coordinates.", parameters = {
        { name = "model" }, { name = "x" }, { name = "y" }, { name = "z" },
        { name = "yaw", optional = true }, { name = "bucket", optional = true }
    } },
    { command = "/prop.here", help = "Create a world prop at your own position.", parameters = {
        { name = "model" }, { name = "yaw", optional = true }
    } },
    { command = "/prop.list", help = "List server-authoritative world props.", parameters = {
        { name = "bucket", help = "Optional routing bucket.", optional = true }
    } },
    { command = "/prop.near", help = "List props around your own position.", parameters = {
        { name = "radius", help = "Metres, default 15.", optional = true }
    } },
    { command = "/prop.remove", help = "Remove a prop owned by this resource.", parameters = {
        { name = "id" }
    } },
    { command = "/prop.move", help = "Move an existing prop to new coordinates.", parameters = {
        { name = "id" }, { name = "x" }, { name = "y" }, { name = "z" },
        { name = "yaw", optional = true }
    } },
    { command = "/prop.clear", help = "Remove every prop owned by this resource." },
    { command = "/prop.catalog", help = "List the curated prop model aliases." },
    { command = "/prop.pickup", help = "Pick up a nearby prop and carry it.", parameters = {
        { name = "id" }
    } },
    { command = "/prop.drop", help = "Drop whatever you are carrying." },
    { command = "/light.toggle", help = "Switch a light off or on without respawning it.",
      parameters = { { name = "id" }, { name = "state", help = "on or off." } } },
    { command = "/light.create", help = "Create a light at explicit coordinates.", parameters = {
        { name = "x" }, { name = "y" }, { name = "z" },
        { name = "intensity", help = "0-10000, default 20.", optional = true },
        { name = "radius", help = "Metres, 0.1-500, default 10.", optional = true },
        { name = "r", help = "0-1, default 1.", optional = true },
        { name = "g", help = "0-1, default 1.", optional = true },
        { name = "b", help = "0-1, default 1.", optional = true }
    } },
    { command = "/light.here", help = "Create a light at your own position.", parameters = {
        { name = "intensity", help = "0-10000, default 20.", optional = true },
        { name = "radius", help = "Metres, 0.1-500, default 10.", optional = true },
        { name = "r", help = "0-1, default 1.", optional = true },
        { name = "g", help = "0-1, default 1.", optional = true },
        { name = "b", help = "0-1, default 1.", optional = true }
    } },
}

RegisterNetEvent("chat:ready", function()
    TriggerClientEvent("chat:addSuggestions", source, CHAT_SUGGESTIONS)
end)

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

-- Every command body runs inside this wrapper: a rejected argument reports the
-- usage line back to the caller instead of unwinding the resource VM.
local function command(name, usage, restricted, handler)
    RegisterCommand(name, function(source, args, raw)
        local ok, err = pcall(handler, source, args, raw)
        if not ok then
            output(source, raw, false, string.format("%s -- usage: %s", tostring(err), usage))
        end
    end, restricted == true)
end

-- Registry records may carry a nested position or the flattened x/y/z used on
-- the wire; accept both rather than trusting one shape.
local function positionOf(record)
    if type(record.position) == "table" then return record.position end
    return { x = record.x, y = record.y, z = record.z }
end

local function describe(record)
    local p = positionOf(record)
    return string.format(
        "id=%s model=%s kind=%s bucket=%s pos=%.2f,%.2f,%.2f yaw=%.1f physics=%s owner=%s",
        tostring(record.id), tostring(record.model), tostring(record.kind or "prop"),
        tostring(record.bucket or 0),
        tonumber(p.x) or 0.0, tonumber(p.y) or 0.0, tonumber(p.z) or 0.0,
        tonumber(record.yaw) or 0.0, tostring(record.physics or "static"),
        tostring(record.resource or GetCurrentResourceName()))
end

-- A command that needs a world position only works for an in-game caller; the
-- dedicated console has no body and therefore no position.
local function callerPosition(source)
    if source == nil or source <= 0 then
        error("this command requires an in-game caller", 0)
    end
    local position = Open77.players.position(source)
    if position == nil then
        error(string.format("player %d has no fresh position snapshot", source), 0)
    end
    return position
end

command("prop.create", "prop.create <model> <x> <y> <z> [yaw] [bucket]", true, function(source, args, raw)
    if args.n < 4 or args.n > 6 then error("wrong argument count", 0) end
    -- Default to the caller's own bucket, not to 0. A player standing in a
    -- routing bucket who creates a prop by coordinates would otherwise get a
    -- prop nobody can see -- the server creates it happily, and it is simply
    -- never projected to anyone. `prop.here` has always used the caller's
    -- bucket; this makes the two commands agree.
    local definition = {
        model = args[1],
        position = { x = number(args[2]), y = number(args[3]), z = number(args[4]) },
        yaw = args[5] and number(args[5]) or 0.0,
        bucket = args[6] and integer(args[6]) or callerPosition(source).bucket,
    }
    local id, reason = Open77.props.create(definition)
    if id == nil then return output(source, raw, false, "prop create failed: " .. tostring(reason)) end
    if PropsPersistence then PropsPersistence.saveCreated(id, definition) end
    output(source, raw, true, string.format("prop %s created (%s)", tostring(id), args[1]))
end)

command("prop.here", "prop.here <model> [yaw]", true, function(source, args, raw)
    if args.n < 1 or args.n > 2 then error("wrong argument count", 0) end
    local position = callerPosition(source)
    local definition = {
        model = args[1],
        position = { x = position.x, y = position.y, z = position.z },
        yaw = args[2] and number(args[2]) or 0.0,
        bucket = position.bucket,
    }
    local id, reason = Open77.props.create(definition)
    if id == nil then return output(source, raw, false, "prop create failed: " .. tostring(reason)) end
    if PropsPersistence then PropsPersistence.saveCreated(id, definition) end
    output(source, raw, true, string.format(
        "prop %s created at player %d (%s, bucket=%s)",
        tostring(id), source, args[1], tostring(position.bucket)))
end)

-- A light is a prop of kind "light". It does not use the caller's model at all:
-- the client routes every light to the one host entity that carries a light
-- component, because the per-alias hosts carry geometry and no light. The model
-- string is still required to be non-empty by the client's validation, so it is
-- passed as a label rather than as a lookup key.
-- The coordinate form. `light.here` is convenient and useless for a controlled
-- test: it puts the light wherever the player happens to be standing, so two
-- captures meant to differ only in colour also differ in position, and every
-- comparison is confounded. This places the light where you say.
-- Switching a light off is the commonest thing anyone will do to one, so it must
-- not respawn the prop. The client applies `enabled` to the live component and
-- re-runs its enable stage; the server side only has to carry the flag.
--
-- The whole light table is sent, not just `enabled`. A patch that omits a field
-- gets that field's default on the client, so a partial patch would silently
-- reset the colour and intensity of the lamp it was meant to switch off.
command("light.toggle", "light.toggle <id> <on|off>", true, function(source, args, raw)
    if args.n ~= 2 then error("wrong argument count", 0) end
    local id = integer(args[1])
    local state = tostring(args[2]):lower()
    if state ~= "on" and state ~= "off" then error("state must be on or off", 0) end

    local found = nil
    for _, record in ipairs(Open77.props.all()) do
        if tostring(record.id) == tostring(id) then found = record break end
    end
    if found == nil then return output(source, raw, false, "no such prop: " .. tostring(id)) end
    if found.kind ~= "light" then
        return output(source, raw, false, "prop " .. tostring(id) .. " is not a light")
    end

    -- A server snapshot carries `light` as the JSON **string** the registry
    -- stores, not as a table -- `PushProp` sets it straight from `LightJson`.
    -- Indexing a string in Lua yields nil through the string metatable rather
    -- than erroring, so `found.light.intensity` was silently nil and every
    -- toggle rewrote the lamp to the defaults below: intensity 20, radius 10,
    -- white, point. The command sends the whole table precisely to avoid that,
    -- and the string/table asymmetry defeated it.
    --
    -- Client-side records give a table, so accept both rather than assuming.
    local light = found.light
    if type(light) == "string" then
        local decoded, err = json.decode(light)
        if type(decoded) ~= "table" then
            return output(source, raw, false,
                "cannot read light state for prop " .. tostring(id) .. ": " .. tostring(err))
        end
        light = decoded
    end
    if type(light) ~= "table" then light = {} end

    local patch = {
        intensity = light.intensity or 20.0,
        radius = light.radius or 10.0,
        color = light.color or { x = 1.0, y = 1.0, z = 1.0 },
        spot = light.spot or false,
        enabled = (state == "on"),
    }
    local ok, reason = Open77.props.update(id, { light = patch })
    if not ok then return output(source, raw, false, "light toggle failed: " .. tostring(reason)) end
    if PropsPersistence then PropsPersistence.saveLight(id, patch) end
    output(source, raw, true, string.format("light %d switched %s", id, state))
end)

command("light.create", "light.create <x> <y> <z> [intensity] [radius] [r] [g] [b]", true,
    function(source, args, raw)
    if args.n < 3 or args.n > 8 then error("wrong argument count", 0) end
    local function channel(index)
        if args[index] == nil then return 1.0 end
        local value = number(args[index])
        if value < 0.0 or value > 1.0 then error("colour channel must be 0-1", 0) end
        return value
    end
    local definition = {
        model = "light",
        kind = "light",
        position = { x = number(args[1]), y = number(args[2]), z = number(args[3]) },
        bucket = callerPosition(source).bucket,
        light = {
            intensity = args[4] and number(args[4]) or 20.0,
            radius = args[5] and number(args[5]) or 10.0,
            color = { x = channel(6), y = channel(7), z = channel(8) },
            enabled = true,
        },
    }
    local id, reason = Open77.props.create(definition)
    if id == nil then return output(source, raw, false, "light create failed: " .. tostring(reason)) end
    if PropsPersistence then PropsPersistence.saveCreated(id, definition) end
    output(source, raw, true, string.format(
        "light %s created at %.2f, %.2f, %.2f",
        tostring(id), number(args[1]), number(args[2]), number(args[3])))
end)

command("light.here", "light.here [intensity] [radius] [r] [g] [b]", true, function(source, args, raw)
    if args.n > 5 then error("wrong argument count", 0) end
    local position = callerPosition(source)
    local function channel(index)
        if args[index] == nil then return 1.0 end
        local value = number(args[index])
        if value < 0.0 or value > 1.0 then error("colour channel must be 0-1", 0) end
        return value
    end
    local definition = {
        model = "light",
        kind = "light",
        position = { x = position.x, y = position.y, z = position.z },
        bucket = position.bucket,
        light = {
            intensity = args[1] and number(args[1]) or 20.0,
            radius = args[2] and number(args[2]) or 10.0,
            color = { x = channel(3), y = channel(4), z = channel(5) },
            enabled = true,
        },
    }
    local id, reason = Open77.props.create(definition)
    if id == nil then return output(source, raw, false, "light create failed: " .. tostring(reason)) end
    if PropsPersistence then PropsPersistence.saveCreated(id, definition) end
    output(source, raw, true, string.format(
        "light %s created at player %d (bucket=%s)",
        tostring(id), source, tostring(position.bucket)))
end)

-- ---------------------------------------------------------------------------
-- Carrying
--
-- The server owns a stable player/bone binding. Every viewer follows its own
-- rendered skeleton; no periodic Lua/network teleports are necessary.
-- ---------------------------------------------------------------------------

local carried = {}          -- [propId] = { player = id, yaw = n }
local CARRY_REACH = 4.0     -- metres; how close you must be to pick something up

local function propById(id, bucket)
    for _, record in ipairs(Open77.props.all(bucket)) do
        if tostring(record.id) == tostring(id) then return record end
    end
    return nil
end

local function carrierOf(id)
    local entry = carried[tostring(id)]
    return entry and entry.player or nil
end

-- Persist the authoritative drop anchor once. Bone animation stays entirely
-- in the native presentation layer; no transform polling/network loop.
local function persistCarryEnd(id, entry)
    local record = Open77.props.get(id)
    if record then entry.last = record.position; entry.yaw = record.yaw end
    if PropsPersistence and entry.last ~= nil then
        PropsPersistence.saveTransform(id,
            entry.last.x, entry.last.y, entry.last.z, entry.yaw)
    end
end

local function dropAllFor(playerId)
    local dropped = 0
    for id, entry in pairs(carried) do
        if entry.player == playerId then
            carried[id] = nil
            Open77.props.detach(id)
            persistCarryEnd(id, entry)
            dropped = dropped + 1
        end
    end
    return dropped
end

command("prop.pickup", "prop.pickup <id>", true, function(source, args, raw)
    if args.n ~= 1 then error("wrong argument count", 0) end
    local id = integer(args[1])
    local origin = callerPosition(source)
    local record = propById(id, origin.bucket)
    if record == nil then return output(source, raw, false, "no such prop here: " .. tostring(id)) end
    if record.kind ~= "prop" then
        return output(source, raw, false, "only a prop can be carried, not a " .. tostring(record.kind))
    end

    local existing = carrierOf(id)
    if existing ~= nil then
        return output(source, raw, false,
            string.format("prop %d is already carried by player %d", id, existing))
    end

    -- Reach is checked on the server, not trusted from the client: picking
    -- something up from across the map is exactly the kind of thing a hostile
    -- resource would try.
    local px = record.position and record.position.x or record.x
    local py = record.position and record.position.y or record.y
    local pz = record.position and record.position.z or record.z
    local dx, dy, dz = px - origin.x, py - origin.y, pz - origin.z
    local distance = math.sqrt(dx * dx + dy * dy + dz * dz)
    if distance > CARRY_REACH then
        return output(source, raw, false,
            string.format("prop %d is %.1f m away; reach is %.1f m", id, distance, CARRY_REACH))
    end

    dropAllFor(source)
    local ok, reason = Open77.props.attach(id, {parentType = "player", parentId = source, bone = "RightHand"})
    if not ok then return output(source, raw, false, "attachment failed: " .. tostring(reason)) end
    carried[tostring(id)] = { player = source, yaw = record.yaw or 0.0 }
    output(source, raw, true, string.format("prop %d picked up by player %d", id, source))
end)

command("prop.drop", "prop.drop", true, function(source, args, raw)
    if args.n ~= 0 then error("wrong argument count", 0) end
    local dropped = dropAllFor(source)
    if dropped == 0 then return output(source, raw, false, "you are not carrying anything") end
    output(source, raw, true, string.format("dropped %d prop(s)", dropped))
end)

AddEventHandler("onPropAttachmentChanged", function(id, attachment)
    local key = tostring(id)
    local entry = carried[key]
    if entry and (not attachment or attachment.parentType ~= "player" or tonumber(attachment.parentId) ~= entry.player) then
        carried[key] = nil
        persistCarryEnd(key, entry)
    end
end)

command("prop.list", "prop.list [bucket]", false, function(source, args, raw)
    if args.n > 1 then error("wrong argument count", 0) end
    local bucket = args[1] and integer(args[1]) or nil
    local records = Open77.props.all(bucket)
    if #records == 0 then return output(source, raw, true, "props: none") end
    output(source, raw, true, string.format("props (%d):", #records))
    for index, record in ipairs(records) do
        if index > MAX_LISTED then
            return output(source, raw, true, string.format("... output limited to %d props", MAX_LISTED))
        end
        output(source, raw, true, describe(record))
    end
end)

command("prop.near", "prop.near [radius]", false, function(source, args, raw)
    if args.n > 1 then error("wrong argument count", 0) end
    local radius = args[1] and number(args[1]) or DEFAULT_NEAR_RADIUS
    if radius <= 0 then error("radius must be positive", 0) end
    local origin = callerPosition(source)

    local found = {}
    for _, record in ipairs(Open77.props.all(origin.bucket)) do
        local p = positionOf(record)
        local dx = (tonumber(p.x) or 0.0) - origin.x
        local dy = (tonumber(p.y) or 0.0) - origin.y
        local dz = (tonumber(p.z) or 0.0) - origin.z
        local distance = math.sqrt(dx * dx + dy * dy + dz * dz)
        if distance <= radius then
            found[#found + 1] = { distance = distance, record = record }
        end
    end
    table.sort(found, function(a, b) return a.distance < b.distance end)

    if #found == 0 then
        return output(source, raw, true, string.format("props: none within %.1fm", radius))
    end
    output(source, raw, true, string.format("props within %.1fm (%d):", radius, #found))
    for index, entry in ipairs(found) do
        if index > MAX_LISTED then
            return output(source, raw, true, string.format("... output limited to %d props", MAX_LISTED))
        end
        output(source, raw, true, string.format("%.1fm %s", entry.distance, describe(entry.record)))
    end
end)

-- Moving a prop is a transform patch, not a respawn: the client keeps the same
-- entity and only its position changes, which is what makes a moving prop look
-- like one object rather than a flicker of two. `Open77.props.setTransform`
-- carries that distinction through to the native layer.
command("prop.move", "prop.move <id> <x> <y> <z> [yaw]", true, function(source, args, raw)
    if args.n < 4 or args.n > 5 then error("wrong argument count", 0) end
    local id = integer(args[1])
    local ok, reason = Open77.props.setTransform(id, {
        position = { x = number(args[2]), y = number(args[3]), z = number(args[4]) },
        yaw = args[5] and number(args[5]) or 0.0,
    })
    if not ok then return output(source, raw, false, "prop move failed: " .. tostring(reason)) end
    if PropsPersistence then
        PropsPersistence.saveTransform(id,
            number(args[2]), number(args[3]), number(args[4]),
            args[5] and number(args[5]) or 0.0)
    end
    output(source, raw, true, string.format(
        "prop %d moved to %.2f, %.2f, %.2f",
        id, number(args[2]), number(args[3]), number(args[4])))
end)

command("prop.remove", "prop.remove <id>", true, function(source, args, raw)
    if args.n ~= 1 then error("wrong argument count", 0) end
    local id = integer(args[1])
    local removed = Open77.props.remove(id)
    if removed == true and PropsPersistence then PropsPersistence.forget(id) end
    output(source, raw, removed == true,
        removed and
        string.format("prop %d removed", id) or
        string.format("prop %d not found or owned by another resource", id))
end)

command("prop.clear", "prop.clear", true, function(source, args, raw)
    if args.n ~= 0 then error("wrong argument count", 0) end
    local removed = Open77.props.clear()
    if PropsPersistence then PropsPersistence.forgetAll() end
    output(source, raw, true, string.format("props cleared (%s)", tostring(removed)))
end)

command("prop.catalog", "prop.catalog", false, function(source, args, raw)
    if args.n ~= 0 then error("wrong argument count", 0) end
    local catalog = Open77.props.catalog()
    if type(catalog) ~= "table" or #catalog == 0 then
        -- Not "empty": the alias table lives in the client plugin
        -- (client/src/api/Props.cpp), and the server-side binding has no copy of
        -- it, so this always comes back empty rather than short. Saying "empty"
        -- reads as "there are no models", which sends people looking for a
        -- catalogue that is not missing -- it is simply not on this side.
        return output(source, raw, true,
            "prop catalog is client-side; the server has no copy. " ..
            "Use `props.catalog` on the debug bridge, or see the props docs for the alias list.")
    end
    output(source, raw, true, string.format("prop catalog (%d):", #catalog))
    for index, entry in ipairs(catalog) do
        if index > MAX_LISTED then
            return output(source, raw, true, string.format("... output limited to %d entries", MAX_LISTED))
        end
        if type(entry) == "table" then
            output(source, raw, true, string.format("%s -> %s",
                tostring(entry.alias or entry.name or index), tostring(entry.model or entry.path or "?")))
        else
            output(source, raw, true, tostring(entry))
        end
    end
end)

-- A client answers every projection with open77:props:projected. A failure here
-- is a client-side fault (missing model, streaming refusal); the registry keeps
-- the record so the next snapshot retries it.
RegisterNetEvent("open77:props:projected", function(id, ok, reason)
    if ok then return end
    print(string.format("prop projection failed player=%s prop=%s reason=%s",
        tostring(source), tostring(id), tostring(reason)))
end)

print("server prop authority ready; commands: prop.create, prop.here, prop.list, prop.near, prop.remove, prop.clear, prop.catalog, prop.move, light.here, light.create, light.toggle, prop.pickup, prop.drop")
