-- Server authority and administration for Open77 world effects.
--
-- Open77.effects is injected by the dedicated-server runtime. One-shots are
-- fire-and-forget broadcasts; looping effects are registry records this
-- resource owns and can retire. This resource owns only what its commands
-- create; gameplay resources use the same API and keep their own.

local MAX_LISTED = 100

local function output(source, raw, success, text)
    print(text)
    if source ~= nil and source > 0 then
        TriggerClientEvent("open77:command:result", source, raw or "", success == true, text)
    end
end

local CHAT_SUGGESTIONS = {
    { command = "/fx.play", help = "Play a one-shot effect at world coordinates.", parameters = {
        { name = "effect" }, { name = "x" }, { name = "y" }, { name = "z" },
        { name = "bucket", optional = true }
    } },
    { command = "/fx.here", help = "Play a one-shot effect at your own position.", parameters = {
        { name = "effect" }
    } },
    { command = "/fx.loop", help = "Register a looping effect at world coordinates.", parameters = {
        { name = "effect" }, { name = "x" }, { name = "y" }, { name = "z" },
        { name = "bucket", optional = true }
    } },
    { command = "/fx.list", help = "List looping effects owned by this resource.", parameters = {
        { name = "bucket", help = "Optional routing bucket.", optional = true }
    } },
    { command = "/fx.stop", help = "Retire a looping effect by id.", parameters = {
        { name = "id" }
    } },
    { command = "/fx.catalog", help = "List the curated effect aliases." },
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
        "id=%s effect=%s bucket=%s pos=%.2f,%.2f,%.2f owner=%s",
        tostring(record.id), tostring(record.name or record.effect),
        tostring(record.bucket or 0),
        tonumber(p.x) or 0.0, tonumber(p.y) or 0.0, tonumber(p.z) or 0.0,
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

command("fx.play", "fx.play <effect> <x> <y> <z> [bucket]", true, function(source, args, raw)
    if args.n < 4 or args.n > 5 then error("wrong argument count", 0) end
    local ok, reason = Open77.effects.play(args[1], {
        position = { x = number(args[2]), y = number(args[3]), z = number(args[4]) },
        bucket = args[5] and integer(args[5]) or callerPosition(source).bucket,
    })
    if not ok then return output(source, raw, false, "fx play failed: " .. tostring(reason)) end
    output(source, raw, true, string.format("fx %s played", args[1]))
end)

command("fx.here", "fx.here <effect>", true, function(source, args, raw)
    if args.n ~= 1 then error("wrong argument count", 0) end
    local position = callerPosition(source)
    local ok, reason = Open77.effects.play(args[1], {
        position = { x = position.x, y = position.y, z = position.z },
        bucket = position.bucket,
    })
    if not ok then return output(source, raw, false, "fx play failed: " .. tostring(reason)) end
    output(source, raw, true, string.format(
        "fx %s played at player %d (bucket=%s)", args[1], source, tostring(position.bucket)))
end)

command("fx.loop", "fx.loop <effect> <x> <y> <z> [bucket]", true, function(source, args, raw)
    if args.n < 4 or args.n > 5 then error("wrong argument count", 0) end
    -- `effect` and `ttlMs`, not `name` and `duration`: the field names come from
    -- the authoritative registry (EffectAuthorityService), and `ttlMs = 0` is
    -- what means "until removed" there.
    local id, reason = Open77.effects.create({
        effect = args[1],
        position = { x = number(args[2]), y = number(args[3]), z = number(args[4]) },
        bucket = args[5] and integer(args[5]) or callerPosition(source).bucket,
        ttlMs = 0,
    })
    if id == nil then return output(source, raw, false, "fx loop failed: " .. tostring(reason)) end
    output(source, raw, true, string.format("fx %s looping as %s", args[1], tostring(id)))
end)

command("fx.list", "fx.list [bucket]", false, function(source, args, raw)
    if args.n > 1 then error("wrong argument count", 0) end
    local bucket = args[1] and integer(args[1]) or nil
    local records = Open77.effects.all(bucket)
    if #records == 0 then return output(source, raw, true, "effects: none") end
    output(source, raw, true, string.format("effects (%d):", #records))
    for index, record in ipairs(records) do
        if index > MAX_LISTED then
            return output(source, raw, true, string.format("... output limited to %d effects", MAX_LISTED))
        end
        output(source, raw, true, describe(record))
    end
end)

command("fx.stop", "fx.stop <id>", true, function(source, args, raw)
    if args.n ~= 1 then error("wrong argument count", 0) end
    local id = integer(args[1])
    local removed = Open77.effects.remove(id)
    output(source, raw, removed == true,
        removed and
        string.format("fx %d stopped", id) or
        string.format("fx %d not found or owned by another resource", id))
end)

command("fx.catalog", "fx.catalog", false, function(source, args, raw)
    if args.n ~= 0 then error("wrong argument count", 0) end
    local catalog = Open77.effects.catalog()
    if type(catalog) ~= "table" or #catalog == 0 then
        return output(source, raw, true, "fx catalog: empty")
    end
    output(source, raw, true, string.format("fx catalog (%d):", #catalog))
    for index, entry in ipairs(catalog) do
        if index > MAX_LISTED then
            return output(source, raw, true, string.format("... output limited to %d entries", MAX_LISTED))
        end
        if type(entry) == "table" then
            output(source, raw, true, string.format("%s -> %s",
                tostring(entry.alias or entry.name or index), tostring(entry.effect or entry.path or "?")))
        else
            output(source, raw, true, tostring(entry))
        end
    end
end)

print("server effect authority ready; commands: fx.play, fx.here, fx.loop, fx.list, fx.stop, fx.catalog")
