-- Equipment client: the local equipment system's changes go up as intents, the
-- server's record comes down and is stated to bodies.

if type(Open77.equipment) ~= "table" or type(Open77.wardrobe) ~= "table" or type(Open77.puppets) ~= "table" then
    print("[open77_equipment] native equipment API unavailable; restart Cyberpunk")
    return
end

-- The slots this resource replicates, as the server and the native layer name them.
local SLOTS = {
    Head = true, Face = true, InnerChest = true, OuterChest = true, Legs = true,
    Feet = true, Outfit = true, UnderwearTop = true, UnderwearBottom = true,
}

-- The server's record for this player is the reference for everything the
-- local side does. A slot value is nil (unset), false (explicitly empty) or an
-- item record.
--
--   * The record exists from the moment the server sends it for this world
--     entry until the next world entry. While there is none, the registry is
--     not this player's statement: the game is loading a save or the body is
--     being reset, and nothing is forwarded.
--   * A registry value that differs from the record is forwarded and becomes
--     the record. Applying the record makes the registry equal to it, so the
--     application itself never echoes. A failed application remains pending
--     and suppresses intents until the authoritative record can be restored.
--   * The record is updated from the server's replication like any other
--     player's, so the comparison is always against what the server holds.
--
-- The record is applied when the registry can be read; `open77:equipment:ready`
-- is the game's equipment attach, which retries the application when the
-- record arrived first.
local record = nil       -- the server's record for this player, as replicated
local pendingApply = false
local previewOwner = nil
local me = nil           -- this player's server id, learned from replication

local function playable()
    local bootstrap = Open77.session.characterBootstrap()
    local player = Open77.character.state()
    return type(bootstrap) == "table" and bootstrap.phase == "ready"
        and bootstrap.playerReset == "complete" and type(player) == "table" and player.alive == true
end

local function forward(slot, value)
    if record == nil or record[slot] == value then return end
    record[slot] = value
    print(("[open77_equipment] %s -> %s"):format(slot, tostring(value)))
    TriggerServerEvent("open77:equipment:slot", slot, value)
end

AddEventHandler("open77:equipment:changed", function(slot, value)
    if previewOwner or pendingApply or not playable() or SLOTS[slot] == nil then return end
    if value == "" then value = false end
    -- Writes report asynchronously. Ignore an intermediate registry value
    -- already superseded by a reset or a later authoritative application.
    local registry = Open77.equipment.registry()
    if type(registry) ~= "table" or (registry[slot] or false) ~= value then return end
    forward(slot, value)
end)

local function apply()
    if record == nil or previewOwner then return end
    pendingApply = true
    if not playable() then return end
    local registry, reason = Open77.equipment.registry()
    if type(registry) ~= "table" then
        print("[open77_equipment] equipment not ready yet: " .. tostring(reason))
        return
    end
    -- The wardrobe first: unequipping clothing while an outfit is shown keeps
    -- the outfit's visuals on the body.
    if record.Wardrobe ~= nil then
        local ok, reason = Open77.wardrobe.activate(record.Wardrobe)
        if not ok then print("[open77_equipment] activating the outfit failed: " .. tostring(reason)) end
    end
    local statement, any = {}, false
    for slot in pairs(SLOTS) do
        if record[slot] ~= nil then statement[slot], any = record[slot], true end
    end
    if any then
        local ok, reason = Open77.equipment.apply(statement, { allowRestricted = true })
        if not ok then
            print("[open77_equipment] stating the server record failed: " .. tostring(reason))
            return
        end
    end
    pendingApply = false

end

RegisterNetEvent("open77:equipment:self", function(slots)
    if type(slots) ~= "table" then return end
    record = slots
    apply()
end)

AddEventHandler("open77:equipment:ready", apply)

AddEventHandler("open77:worldReady", function()
    record = nil
    pendingApply = false
end)

-- Replication: one slot or a whole record, for any player, this one included.
RegisterNetEvent("open77:equipment:slot", function(player, slot, value)
    player = tonumber(player)
    if player == nil or SLOTS[slot] == nil then return end
    if player ~= me then
        Open77.puppets.setSlot(player, slot, value)
        return
    end
    -- The server changed this player's record: the body follows it. Applying
    -- makes the registry equal to the record, so nothing is forwarded back.
    if record == nil then return end
    record[slot] = value
    if previewOwner then return end
    local ok, reason
    if value then ok, reason = Open77.equipment.equip(value, slot, { allowRestricted = true })
    else ok, reason = Open77.equipment.unequip(slot) end
    if not ok then print(("[open77_equipment] stating %s failed: %s"):format(slot, tostring(reason))) end
end)

RegisterNetEvent("open77:equipment:record", function(player, slots)
    player = tonumber(player)
    if player == nil or type(slots) ~= "table" then return end
    if player == me then return end
    for slot in pairs(SLOTS) do
        Open77.puppets.setSlot(player, slot, slots[slot])
    end
end)

RegisterNetEvent("open77:equipment:me", function(player)
    me = tonumber(player)
end)

-- The local equipment API, for resources that keep to this one.
exports("slots", function() return Open77.equipment.slots() end)
exports("records", function(options) return Open77.equipment.records(options) end)
exports("info", function(record) return Open77.equipment.info(record) end)
exports("registry", function() return Open77.equipment.registry() end)
exports("equip", function(record, slot, options) return Open77.equipment.equip(record, slot, options) end)
exports("unequip", function(slot) return Open77.equipment.unequip(slot) end)
exports("apply", function(slots, options) return Open77.equipment.apply(slots, options) end)

print("equipment client ready")

-- Resource startup/reload and transient equipment attachment failures retain
-- the authoritative request. Never publish failed applications as new intent.
CreateThread(function()
    while true do
        Wait(1000)
        local bootstrap = Open77.session.characterBootstrap()
        if type(bootstrap) == "table" and bootstrap.phase == "ready" and bootstrap.playerReset == "complete" then
            if record == nil then TriggerServerEvent("open77:presentation:request")
            elseif pendingApply then apply() end
        end
    end
end)

-- Compatibility for server resources using the existing asynchronous clothing
-- API. The equipment registry reports these writes through the normal authority.
local oldSlots = { head="Head", face="Face", inner_chest="InnerChest", outer_chest="OuterChest",
    legs="Legs", feet="Feet", outfit="Outfit" }
local oldOrder = { "head", "face", "inner_chest", "outer_chest", "legs", "feet", "outfit" }
local attachments = { Head="Head", Face="Eyes", InnerChest="Chest", OuterChest="Torso",
    Legs="Legs", Feet="Feet", Outfit="Outfit" }
local function legacySnapshot(wanted)
    local registry, reason = Open77.equipment.registry()
    if not registry then return nil, reason end
    local rows = {}
    for _, name in ipairs(oldOrder) do
        local slot = oldSlots[name]
        local value = registry[slot]
        local row = { slot=name, attachmentSlot="AttachmentSlots." .. attachments[slot], equipped=not not value }
        if value then
            local info = Open77.equipment.info(value)
            row.record = info and info.record or value
            row.tweakDbId = info and info.tweakDbId or value
        end
        if wanted == slot then return row end
        rows[#rows + 1] = row
    end
    return rows
end
RegisterNetEvent("open77:clothing:request", function(request, operation, payload, options)
    if type(request) == "number" then
        if request % 1 ~= 0 or request <= 0 then return end
    elseif type(request) ~= "string" or #request == 0 or #request > 96 then return end
    local result, reason, wanted
    if operation == "equip" then
        result, reason = Open77.equipment.equip(payload, options)
        local info = result and Open77.equipment.info(payload)
        wanted = info and info.slot
    elseif operation == "unequip" then
        wanted = oldSlots[payload] or payload
        result, reason = Open77.equipment.unequip(wanted)
    elseif operation == "clear" then
        local statement = {}
        for _, slot in pairs(oldSlots) do statement[slot] = false end
        result, reason = Open77.equipment.apply(statement)
    elseif operation == "set" and type(payload) == "table" then
        local statement = {}
        for slot, item in pairs(payload) do statement[oldSlots[slot] or slot] = item end
        result, reason = Open77.equipment.apply(statement, options)
    elseif operation == "all" then
        result = true
    else reason = "unsupported_operation" end
    if result then result, reason = legacySnapshot(wanted) end
    TriggerServerEvent("open77:clothing:result", request, operation, result ~= nil and result ~= false,
        reason or "", result)
end)

-- The fitting room owns temporary native mutations, never server intent.
exports("beginPreview", function()
    local owner = GetInvokingResource()
    if owner ~= "open77_wardrobe_ui" then return nil, "preview_owner_denied" end
    if previewOwner or record == nil or pendingApply or not playable() then return nil, "presentation_not_ready" end
    previewOwner = owner
    return true
end)
exports("endPreview", function()
    if GetInvokingResource() ~= previewOwner then return nil, "preview_owner_denied" end
    previewOwner = nil
    apply()
    return true
end)
AddEventHandler("onClientResourceStop", function(name)
    if name == previewOwner then previewOwner = nil; apply() end
end)
