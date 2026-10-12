-- Server authority and administration for Open77 world loot.
--
-- Open77.loot is injected by the dedicated-server runtime. This resource owns
-- only the test drops created by its commands; gameplay resources can use the
-- same API and retain ownership of their own drops.

local function output(source, raw, success, text)
    print(text)
    if source ~= nil and source > 0 then
        TriggerClientEvent("open77:command:result", source, raw or "", success == true, text)
    end
end

local CHAT_SUGGESTIONS = {
    { command = "/loot", help = "List server-authoritative loot drops.", parameters = {
        { name = "bucket", help = "Optional routing bucket.", optional = true }
    } },
    { command = "/loot.list", help = "List server-authoritative loot drops.", parameters = {
        { name = "bucket", help = "Optional routing bucket.", optional = true }
    } },
    { command = "/loot.create", help = "Create a loot drop at world coordinates.", parameters = {
        { name = "item" }, { name = "quantity" }, { name = "x" }, { name = "y" }, { name = "z" },
        { name = "bucket", optional = true }, { name = "radius", optional = true },
        { name = "visualItem", optional = true }
    } },
    { command = "/loot.create.player", help = "Create a loot drop at a player's position.", parameters = {
        { name = "playerId" }, { name = "item" }, { name = "quantity" },
        { name = "offsetZ", optional = true }, { name = "radius", optional = true },
        { name = "visualItem", optional = true }
    } },
    { command = "/loot.remove", help = "Remove a loot drop owned by this resource.", parameters = {
        { name = "id" }
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

local function printDrops(source, raw, bucket)
    local drops = Open77.loot.all(bucket)
    if #drops == 0 then
        output(source, raw, true, "loot: no drops")
        return
    end
    output(source, raw, true, string.format("loot (%d):", #drops))
    for index, drop in ipairs(drops) do
        if index > 100 then
            output(source, raw, true, "... output limited to 100 drops")
            break
        end
        output(source, raw, true, string.format(
            "id=%d item=%s qty=%d bucket=%d pos=%.2f,%.2f,%.2f owner=%s",
            drop.id, drop.item, drop.quantity, drop.bucket,
            drop.x, drop.y, drop.z, drop.resource))
    end
end

RegisterCommand("loot", function(source, args, raw)
    if args.n > 1 then return output(source, raw, false, "usage: loot [bucket]") end
    printDrops(source, raw, args[1] and integer(args[1]) or nil)
end, false)

RegisterCommand("loot.list", function(source, args, raw)
    if args.n > 1 then return output(source, raw, false, "usage: loot.list [bucket]") end
    printDrops(source, raw, args[1] and integer(args[1]) or nil)
end, false)

RegisterCommand("loot.create", function(source, args, raw)
    if args.n < 5 or args.n > 8 then
        return output(source, raw, false, "usage: loot.create <item> <quantity> <x> <y> <z> [bucket] [radius] [visualItem]")
    end
    local id, reason = Open77.loot.create({
        item = args[1],
        quantity = integer(args[2]),
        position = { x = number(args[3]), y = number(args[4]), z = number(args[5]) },
        bucket = args[6] and integer(args[6]) or 0,
        radius = args[7] and number(args[7]) or 2.0,
        visualItem = args[8],
    })
    if id == nil then return output(source, raw, false, "loot create failed: " .. tostring(reason)) end
    output(source, raw, true, string.format("loot %d created (%s x%d)", id, args[1], integer(args[2])))
end, true)

RegisterCommand("loot.create.player", function(source, args, raw)
    if args.n < 3 or args.n > 6 then
        return output(source, raw, false, "usage: loot.create.player <playerId> <item> <quantity> [offsetZ] [radius] [visualItem]")
    end
    local playerId = integer(args[1])
    local position = Open77.players.position(playerId)
    if position == nil then
        return output(source, raw, false, string.format("player %d has no fresh position snapshot", playerId))
    end
    local id, reason = Open77.loot.create({
        item = args[2],
        quantity = integer(args[3]),
        position = {
            x = position.x,
            y = position.y,
            z = position.z + (args[4] and number(args[4]) or 1.0),
        },
        bucket = position.bucket,
        radius = args[5] and number(args[5]) or 2.0,
        visualItem = args[6],
    })
    if id == nil then return output(source, raw, false, "loot create failed: " .. tostring(reason)) end
    output(source, raw, true, string.format(
        "loot %d created at player %d (%s x%d, bucket=%d)",
        id, playerId, args[2], integer(args[3]), position.bucket))
end, true)

RegisterCommand("loot.remove", function(source, args, raw)
    if args.n ~= 1 then return output(source, raw, false, "usage: loot.remove <id>") end
    local id = integer(args[1])
    local removed = Open77.loot.remove(id)
    output(source, raw, removed,
        removed and
        string.format("loot %d removed", id) or
        string.format("loot %d not found or owned by another resource", id))
end, true)

AddEventHandler("onLootPickup", function(playerId, dropId, item, quantity, ownerResource)
    if ownerResource ~= GetCurrentResourceName() then return end
    print(string.format(
        "pickup accepted player=%s drop=%s item=%s quantity=%s",
        tostring(playerId), tostring(dropId), tostring(item), tostring(quantity)))
    TriggerEvent("open77:loot:pickedUp", playerId, dropId, item, quantity)
end)

print("server loot authority ready; commands: loot, loot.create, loot.create.player, loot.remove")
