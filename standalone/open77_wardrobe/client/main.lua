-- Wardrobe client: the game's wardrobe on the local player and the server's
-- record of it are kept equal. A game change that differs from the record goes
-- up as an intent; the record comes down and is stated to the game (for this
-- player) or to the proxy (for anyone else). The wardrobe is transmog: an
-- active outfit is what clothing is shown as.

if type(Open77.wardrobe) ~= "table" or type(Open77.equipment) ~= "table" or type(Open77.puppets) ~= "table" then
    print("[open77_wardrobe] native wardrobe API unavailable; restart Cyberpunk")
    return
end

local OUTFITS = 7
local CLOTHING = {"Head", "Face", "InnerChest", "OuterChest", "Legs", "Feet", "Outfit"}
local record = nil -- the server's record for this player: { active = index|nil, outfits = { [index] = { Slot = record|false } } }
local pending = nil
local awaitingVerification = false
local applying = false
local previewOwner = nil
local me = nil     -- this player's server id, learned from replication

local function playable()
    local bootstrap = Open77.session.characterBootstrap()
    local player = Open77.character.state()
    if not (type(bootstrap) == "table" and bootstrap.phase == "ready"
        and bootstrap.playerReset == "complete" and type(player) == "table" and player.alive == true) then return false end
    -- Body customization must finish before wardrobe mutations or native intent
    -- publication. This narrow export deliberately does not wait on clothing.
    local promise = Open77.exports.call("open77_appearance", "wardrobeMutationReady")
    return promise ~= nil and promise:await() == true
end

-- "Slot=Record|Slot=Record" as the native layer reports an outfit.
local function parseItems(text)
    local items = {}
    if type(text) ~= "string" then return items end
    for pair in text:gmatch("[^|]+") do
        local slot, item = pair:match("^([^=]+)=(.+)$")
        if slot and item then items[slot] = item ~= "-" and item or false end
    end
    return items
end

local function sameOutfit(a, b)
    if type(a) ~= "table" or type(b) ~= "table" then return false end
    for slot, item in pairs(a) do if b[slot] ~= item then return false end end
    for slot, item in pairs(b) do if a[slot] ~= item then return false end end
    return true
end

local function outfitOf(wardrobe, index)
    local outfits = type(wardrobe) == "table" and wardrobe.outfits or nil
    if type(outfits) ~= "table" then return nil end
    return outfits[index] or outfits[tostring(index)]
end

-- The game's wardrobe reports a change; it is this player's intent when it
-- differs from the record.
AddEventHandler("open77:wardrobe:active", function(outfit)
    outfit = tonumber(outfit)
    if outfit == nil or outfit < 0 then outfit = nil end
    if previewOwner or applying or pending or not playable() or record == nil or record.active == outfit then return end
    if previewOwner or applying or pending then return end -- the readiness export may yield
    local current = Open77.wardrobe.active()
    if current == false then current = nil end
    if current ~= outfit then return end
    record.active = outfit
    TriggerServerEvent("open77:wardrobe:active", outfit)
end)

AddEventHandler("open77:wardrobe:outfit", function(outfit, text)
    outfit = tonumber(outfit)
    if previewOwner or applying or pending or not playable() or record == nil or outfit == nil or outfit < 0 then return end
    if previewOwner or applying or pending then return end
    local items = parseItems(text)
    -- Events are queued: ignore an older mutation superseded before delivery.
    local current = Open77.wardrobe.outfit(outfit).registry()
    if not sameOutfit(current, items) then return end
    if sameOutfit(outfitOf(record, outfit), items) then return end
    record.outfits[outfit] = items
    TriggerServerEvent("open77:wardrobe:outfit", outfit, items)
end)

-- The server's record stated to the game's wardrobe on this player: each
-- outfit as one change, then the shown outfit. What is already so changes
-- nothing; what changes reports back equal to the record.
local function state(wardrobe)
    pending = wardrobe
    awaitingVerification = false
    if previewOwner or not playable() or pending ~= wardrobe or previewOwner then return end
    record = { active=tonumber(wardrobe.active), outfits={} }
    for index = 0, OUTFITS - 1 do record.outfits[index] = outfitOf(wardrobe, index) or {} end
    applying = true
    local complete = true
    for index = 0, OUTFITS - 1 do
        local ok, reason = Open77.wardrobe.outfit(index).apply(record.outfits[index], { allowRestricted=true, replace=true })
        if not ok then
            complete = false
            print(("[open77_wardrobe] outfit %d: %s"):format(index, tostring(reason)))
        end
    end
    local ok, reason = Open77.wardrobe.activate(record.active or false)
    if not ok then complete = false; print("[open77_wardrobe] activate: " .. tostring(reason)) end
    applying = false
    -- Native calls can enqueue changes, and equipment restoration may run after
    -- this callback. Success is not proof that the active index stayed applied.
    -- Keep intent publication blocked until the next timer observes the entire
    -- canonical wardrobe, including explicit hidden slots.
    awaitingVerification = complete
end

local function restored()
    if not awaitingVerification or previewOwner or not record or not playable() then return false end
    if not awaitingVerification or previewOwner or not record then return false end
    if Open77.wardrobe.active() ~= (record.active or false) then return false end
    for index=0,OUTFITS-1 do
        if not sameOutfit(Open77.wardrobe.outfit(index).registry(), record.outfits[index]) then return false end
    end
    -- An equipment attach can finish after the overlay's synchronous registry
    -- write and restore the underlying garment appearance. Keep restoration
    -- pending until the actual projection agrees, so the next tick repairs it.
    local equipment = Open77.equipment.registry()
    if type(equipment) ~= "table" then return false end
    local shown = record.active and outfitOf(record, record.active) or {}
    for _, slot in ipairs(CLOTHING) do
        local expected = shown[slot]
        if expected == nil then expected = equipment[slot] end
        local info = expected and Open77.equipment.info(expected)
        if info and info.nonvisual then expected = false end
        if Open77.equipment.visualSettled(slot, expected or false) ~= true then return false end
    end
    return true
end

AddEventHandler("open77:worldReady", function() record=nil; pending=nil; awaitingVerification=false end)
AddEventHandler("open77:equipment:ready", function() if pending then state(pending) end end)
CreateThread(function()
    while true do
        Wait(1000)
        local bootstrap = Open77.session.characterBootstrap()
        if type(bootstrap) == "table" and bootstrap.phase == "ready" and bootstrap.playerReset == "complete" then
            if pending then
                if restored() then pending=nil; awaitingVerification=false
                else state(pending) end
            elseif record == nil then TriggerServerEvent("open77:presentation:request") end
        end
    end
end)

RegisterNetEvent("open77:wardrobe:me", function(player)
    me = tonumber(player)
end)

RegisterNetEvent("open77:wardrobe:self", function(wardrobe)
    if type(wardrobe) == "table" then state(wardrobe) end
end)

RegisterNetEvent("open77:wardrobe:record", function(player, wardrobe)
    player = tonumber(player)
    if player == nil or type(wardrobe) ~= "table" then return end
    if player == me then
        state(wardrobe)
        return
    end
    local outfits = {}
    if type(wardrobe.outfits) == "table" then
        for index, items in pairs(wardrobe.outfits) do
            index = tonumber(index)
            if index ~= nil and type(items) == "table" then outfits[index] = items end
        end
    end
    Open77.puppets.setWardrobe(player, { active = tonumber(wardrobe.active), outfits = outfits })
end)

print("wardrobe client ready")

exports("beginPreview", function()
    local owner = GetInvokingResource()
    if owner ~= "open77_wardrobe_ui" then return nil, "preview_owner_denied" end
    if previewOwner or record == nil or pending or not playable() then return nil, "presentation_not_ready" end
    if previewOwner or record == nil or pending then return nil, "presentation_not_ready" end
    previewOwner = owner
    return true
end)
exports("endPreview", function()
    if GetInvokingResource() ~= previewOwner then return nil, "preview_owner_denied" end
    previewOwner = nil
    if pending or record then state(pending or record) end
    return true
end)
AddEventHandler("onClientResourceStop", function(name)
    if name == previewOwner then
        previewOwner = nil
        if pending or record then state(pending or record) end
    end
end)
