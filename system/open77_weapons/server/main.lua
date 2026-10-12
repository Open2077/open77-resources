-- Open77.weapons is installed independently in every server resource VM. This
-- package owns the authenticated target-client relay and the ACL-gated operator
-- commands. RegisterCommand(..., true) makes the server require the exact
-- `command.weapon.give` / `command.weapon.remove` / `command.weapon.ammo`
-- permission before Lua runs.

local pendingCommands = {}

local function output(source, raw, success, text)
    text = tostring(text or "")
    print(text)
    if source ~= nil and source > 0 then
        TriggerClientEvent(
            "open77:command:result", source, raw or "", success == true, text)
    end
end

local function integer(value)
    local parsed = tonumber(value)
    if parsed == nil or parsed % 1 ~= 0 then return nil end
    return parsed
end

local function targetPlayer(source, value)
    if type(value) == "string" and value:lower() == "me" then
        if source == nil or source <= 0 then return nil, "'me' is unavailable from the server console" end
        return source
    end
    local playerId = integer(value)
    if playerId == nil or playerId <= 0 then return nil, "invalid playerId" end
    if Open77.players.name(playerId) == nil then return nil, "player is not online" end
    return playerId
end

local function boolean(value, default)
    if value == nil then return default end
    value = tostring(value):lower()
    if value == "true" or value == "1" or value == "yes" or value == "on"
        or value == "active" or value == "drawn" then return true end
    if value == "false" or value == "0" or value == "no" or value == "off"
        or value == "inactive" or value == "holstered" then return false end
    return nil
end

local function remember(requestId, source, raw, command, target, record, slot, reserve, magazine)
    local key = tostring(requestId)
    pendingCommands[key] = {
        source = source,
        raw = raw,
        command = command,
        target = target,
        record = record,
        slot = slot,
        reserve = reserve,
        magazine = magazine,
    }
    SetTimeout(11000, function()
        local pending = pendingCommands[key]
        if pending == nil then return end
        pendingCommands[key] = nil
        output(pending.source, pending.raw, false, string.format(
            "%s timed out for player %d", pending.command, pending.target))
    end)
end

local CHAT_SUGGESTIONS = {
    {
        command = "/weapon.give",
        help = "Admin: assign a weapon template to an online player.",
        parameters = {
            { name = "playerId|me" },
            { name = "template" },
            { name = "slot", optional = true },
            { name = "active", optional = true },
        },
    },
    {
        command = "/weapon.remove",
        help = "Admin: clear one weapon slot without deleting its inventory item.",
        parameters = {
            { name = "playerId|me" },
            { name = "slot" },
        },
    },
    {
        command = "/weapon.ammo",
        help = "Admin: set exact spare ammo and optionally the loaded magazine.",
        parameters = {
            { name = "playerId|me" },
            { name = "slot" },
            { name = "reserve" },
            { name = "magazine", optional = true },
        },
    },
}

RegisterNetEvent("chat:ready", function()
    TriggerClientEvent("chat:addSuggestions", source, CHAT_SUGGESTIONS)
end)

RegisterCommand("weapon.give", function(source, args, raw)
    if args.n < 2 or args.n > 4 then
        return output(source, raw, false,
            "usage: weapon.give <playerId|me> <template> [slot=1] [active=true]")
    end
    local playerId, targetReason = targetPlayer(source, args[1])
    if playerId == nil then return output(source, raw, false, targetReason) end
    local slot = args[3] == nil and 1 or integer(args[3])
    if slot == nil or slot < 1 or slot > 3 then
        return output(source, raw, false, "slot must be 1, 2 or 3")
    end
    local active = boolean(args[4], true)
    if active == nil then
        return output(source, raw, false,
            "active must be true/false, on/off, yes/no or 1/0")
    end
    local record = tostring(args[2] or "")
    local requestId, reason = Open77.weapons.assign(
        playerId, record, slot, { active = active, addToInventory = true })
    if requestId == nil then
        return output(source, raw, false, "weapon.give rejected: " .. tostring(reason))
    end
    remember(requestId, source, raw, "weapon.give", playerId, record, slot)
    output(source, raw, true, string.format(
        "weapon.give queued request=%s player=%d template=%s slot=%d active=%s",
        tostring(requestId), playerId, record, slot, tostring(active)))
end, true)

RegisterCommand("weapon.ammo", function(source, args, raw)
    if args.n < 3 or args.n > 4 then
        return output(source, raw, false,
            "usage: weapon.ammo <playerId|me> <slot> <reserve> [magazine]")
    end
    local playerId, targetReason = targetPlayer(source, args[1])
    if playerId == nil then return output(source, raw, false, targetReason) end
    local slot = integer(args[2])
    if slot == nil or slot < 1 or slot > 3 then
        return output(source, raw, false, "slot must be 1, 2 or 3")
    end
    local reserve = integer(args[3])
    local magazine = args[4] == nil and nil or integer(args[4])
    if reserve == nil or reserve < 0 or reserve > 1000000
        or args[4] ~= nil and (magazine == nil or magazine < 0 or magazine > 1000000) then
        return output(source, raw, false,
            "reserve and magazine must be integers from 0 to 1000000")
    end
    local amounts = { reserve = reserve, activate = true }
    if magazine ~= nil then amounts.magazine = magazine end
    local requestId, reason = Open77.weapons.setAmmo(playerId, slot, amounts)
    if requestId == nil then
        return output(source, raw, false, "weapon.ammo rejected: " .. tostring(reason))
    end
    remember(requestId, source, raw, "weapon.ammo", playerId, nil, slot,
        reserve, magazine)
    output(source, raw, true, string.format(
        "weapon.ammo queued request=%s player=%d slot=%d reserve=%d magazine=%s",
        tostring(requestId), playerId, slot, reserve,
        magazine == nil and "keep" or tostring(magazine)))
end, true)

RegisterCommand("weapon.remove", function(source, args, raw)
    if args.n ~= 2 then
        return output(source, raw, false,
            "usage: weapon.remove <playerId|me> <slot>")
    end
    local playerId, targetReason = targetPlayer(source, args[1])
    if playerId == nil then return output(source, raw, false, targetReason) end
    local slot = integer(args[2])
    if slot == nil or slot < 1 or slot > 3 then
        return output(source, raw, false, "slot must be 1, 2 or 3")
    end
    local requestId, reason = Open77.weapons.remove(playerId, slot)
    if requestId == nil then
        return output(source, raw, false, "weapon.remove rejected: " .. tostring(reason))
    end
    remember(requestId, source, raw, "weapon.remove", playerId, nil, slot)
    output(source, raw, true, string.format(
        "weapon.remove queued request=%s player=%d slot=%d",
        tostring(requestId), playerId, slot))
end, true)

RegisterCommand("weapon.clear", function(source, args, raw)
    if args.n ~= 1 then
        return output(source, raw, false, "usage: weapon.clear <playerId|me>")
    end
    local playerId, targetReason = targetPlayer(source, args[1])
    if playerId == nil then return output(source, raw, false, targetReason) end
    -- One request, not three. The owner runs the three native removals and answers
    -- once; a slot that was already empty is not a failure of "remove everything".
    local requestId, reason = Open77.weapons.clear(playerId)
    if requestId == nil then
        return output(source, raw, false, "weapon.clear rejected: " .. tostring(reason))
    end
    remember(requestId, source, raw, "weapon.clear", playerId)
    output(source, raw, true, string.format(
        "weapon.clear queued request=%s player=%d", tostring(requestId), playerId))
end, true)

-- The server's own picture of a loadout, answered NOW.
--
-- The three commands above ask the client to change something and report back
-- later. This one asks nothing: it reads the cache the host keeps from the
-- packets the client already sends, which is the whole point of the row. It is
-- also why the readout prints two ages -- the drawn weapon rides the 20 Hz
-- snapshot, the slot list only arrives when the loadout changes, and an operator
-- staring at a stale slot list deserves to be told which half is old.
RegisterCommand("weapon.read", function(source, args, raw)
    if args.n ~= 1 then
        return output(source, raw, false, "usage: weapon.read <playerId|me>")
    end
    local playerId, targetReason = targetPlayer(source, args[1])
    if playerId == nil then return output(source, raw, false, targetReason) end
    local read, reason = Open77.weapons.get(playerId)
    if read == nil then
        return output(source, raw, false, "weapon.read: " .. tostring(reason))
    end
    local lines = {}
    for _, slot in ipairs(read.slots) do
        local ammo = slot.ammo or {}
        lines[#lines + 1] = string.format("%d=%s%s%s", slot.slot,
            slot.record ~= nil and slot.record ~= "" and slot.record
                or (slot.tweakDbId or "empty"),
            slot.active and "*" or "",
            ammo.magazine ~= nil and ("[" .. tostring(ammo.magazine) .. "]") or "")
    end
    output(source, raw, true, string.format(
        "weapon.read player=%d active=%s drawn=%s magazine=%s source=%s reportedAgeMs=%s "
        .. "loadoutAgeMs=%s slots{%s}",
        playerId, tostring(read.active or "none"), tostring(read.drawn),
        tostring(read.magazine or "unknown"), read.source,
        tostring(read.reportedAgeMs or "never"), tostring(read.loadoutAgeMs or "never"),
        table.concat(lines, " ")))
end, true)

AddEventHandler("open77:weapons:completed", function(
    playerId, requestId, operation, accepted, reason, result)
    local key = tostring(requestId)
    local pending = pendingCommands[key]
    if pending == nil or pending.target ~= playerId then return end
    pendingCommands[key] = nil
    if accepted ~= true then
        return output(pending.source, pending.raw, false, string.format(
            "%s failed for player %d: %s",
            pending.command, pending.target, tostring(reason or "weapon_request_failed")))
    end
    result = type(result) == "table" and result or {}
    if pending.command == "weapon.ammo" then
        local ammo = type(result.ammo) == "table" and result.ammo or {}
        local ammoName = type(ammo.record) == "string" and #ammo.record > 0
            and ammo.record or ammo.tweakDbId or "unknown"
        return output(pending.source, pending.raw, true, string.format(
            "weapon.ammo completed player=%d slot=%s reserve=%s magazine=%s/%s total=%s ammo=%s",
            pending.target, tostring(result.slot or pending.slot),
            tostring(ammo.reserve or pending.reserve),
            tostring(ammo.magazine or pending.magazine or "unknown"),
            tostring(ammo.capacity or "unknown"), tostring(ammo.total or "unknown"),
            tostring(ammoName)))
    end
    if pending.command == "weapon.clear" then
        local parts = {}
        for _, slot in ipairs(type(result.slots) == "table" and result.slots or {}) do
            parts[#parts + 1] = tostring(slot.slot) .. "=" ..
                (slot.accepted and "cleared" or tostring(slot.reason or "failed"))
        end
        return output(pending.source, pending.raw, true, string.format(
            "weapon.clear completed player=%d cleared=%s slots{%s}",
            pending.target, tostring(result.cleared or 0), table.concat(parts, " ")))
    end
    output(pending.source, pending.raw, true, string.format(
        "%s completed player=%d slot=%s template=%s active=%s drawn=%s",
        pending.command, pending.target, tostring(result.slot or pending.slot),
        tostring(result.record or pending.record or ""),
        tostring(result.active == true), tostring(result.drawn == true)))
end)

AddEventHandler("playerDropped", function(playerId)
    -- `source` first: the host sets it, and the first argument is the REASON.
    local dropped = tonumber(source) or tonumber(playerId)
    if dropped == nil then return end
    for requestId, pending in pairs(pendingCommands) do
        if pending.source == dropped or pending.target == dropped then
            pendingCommands[requestId] = nil
        end
    end
end)

print("server weapon loadout relay ready; admin commands: weapon.give, weapon.remove, weapon.ammo, weapon.clear, weapon.read")
