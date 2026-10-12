-- Native right-hand items are projected by open77_props onto the presented
-- body. This resource observes attachment completion; clothing keeps its relay.
if type(Open77.equipment) ~= "table" or type(Open77.equipment.apply) ~= "function" then
    print("[open77_helditems] native equipment API unavailable; restart Cyberpunk")
    return
end

-- The ten AttachmentSlots.* records the client compiles in client/src/game/
-- Slot.hpp. This is the vocabulary Open77.heldItems speaks, and it is closed:
-- it is the only slot list in the tree that is validated rather than authored
-- per entity. `WeaponRight` is the right hand.
local SLOTS = {
    Head = true, Face = true, InnerChest = true, OuterChest = true, Legs = true,
    Feet = true, Outfit = true, UnderwearTop = true, UnderwearBottom = true,
    WeaponRight = true,
}

-- What this resource put where, so a release can tell "empty it" from "it was
-- never ours". Deliberately not an authority: the body's equipment registry is,
-- and `snapshot` reads that instead of trusting this table.
local held = {}
local nativeHeld

local function report(requestId, operation, accepted, reason, result)
    TriggerServerEvent("open77:helditem:result", requestId, operation,
        accepted == true, tostring(reason or ""), result)
end

local function validRequestId(requestId)
    if type(requestId) == "number" then return requestId % 1 == 0 and requestId > 0 end
    return type(requestId) == "string" and #requestId > 0 and #requestId <= 96
end

local function playable()
    local bootstrap = Open77.session.characterBootstrap()
    local player = Open77.character.state()
    return type(bootstrap) == "table" and bootstrap.phase == "ready"
        and type(player) == "table" and player.alive == true
end

local function slotOf(payload)
    if type(payload) ~= "table" then return nil end
    local slot = payload.slot
    if type(slot) ~= "string" or SLOTS[slot] == nil then return nil end
    return slot
end

local function state(slot, value)
    -- `allowRestricted` so an arbitrary item record resolves; `replace` left
    -- false so the statement touches this slot and nothing else. Clothing the
    -- player is wearing, the wardrobe outfit and every other slot survive.
    return Open77.equipment.apply({ [slot] = value }, { allowRestricted = true })
end

local function snapshot()
    local registry, reason = Open77.equipment.registry()
    if type(registry) ~= "table" then return nil, reason or "equipment_unavailable" end
    local slots = {}
    for slot in pairs(SLOTS) do
        local value = registry[slot]
        slots[slot] = {
            record = type(value) == "string" and value or nil,
            empty = value == false or value == nil,
            held = held[slot] ~= nil,
        }
    end
    if nativeHeld then
        local projection = Open77.props.projected and Open77.props.projected(nativeHeld.id)
        slots.WeaponRight = { record = projection and nativeHeld.record or nil,
            empty = not (projection and projection.rendered), held = projection ~= nil,
            attachmentStatus = projection and projection.attachmentStatus or "not_projected" }
    end
    return slots
end

local function hold(payload)
    local slot = slotOf(payload)
    if slot == nil then return false, "invalid_slot" end
    if slot == "WeaponRight" then return false, "use_server_held_items" end
    local record = type(payload) == "table" and payload.record or nil
    if type(record) ~= "string" or #record == 0 then return false, "invalid_item_record" end
    -- A body that is not incarnated has no equipment system to write to, and a
    -- write there is the "alive=no" class of crash the testing rules name.
    if not playable() then return false, "player_not_ready" end
    local ok, reason = state(slot, record)
    if not ok then return false, reason or "equipment_refused" end
    held[slot] = record
    return true, nil, { slot = slot, record = record }
end

local function release(payload)
    local slot = slotOf(payload)
    if slot == "WeaponRight" then return false, "use_server_held_items" end
    if slot == nil then return false, "invalid_slot" end
    if not playable() then return false, "player_not_ready" end
    local ok, reason = state(slot, false)
    if not ok then return false, reason or "equipment_refused" end
    held[slot] = nil
    return true, nil, { slot = slot }
end

local function nativeRequest(requestId, operation, payload)
    if type(Open77.props) ~= "table" or type(Open77.props.projected) ~= "function" then
        report(requestId, operation, false, "native_item_backend_unavailable")
        return
    end
    local propId = tonumber(payload.propId)
    if operation == "hold" then nativeHeld = { id = propId, record = payload.record }
    elseif nativeHeld and nativeHeld.id == propId then nativeHeld = nil end
    CreateThread(function()
        for _ = 1, 90 do
            local projection = propId and Open77.props.projected(propId) or nil
            if operation == "release" and projection == nil then
                report(requestId, operation, true, nil, { slot = "WeaponRight" })
                return
            end
            if operation == "hold" and projection then
                local status = projection.attachmentStatus
                if projection.rendered or status == "hidden_first_person" then
                    report(requestId, operation, true, nil, {
                        slot = "WeaponRight", record = payload.record, propId = propId,
                        rendered = projection.rendered, attachmentStatus = status,
                    })
                    return
                end
                if projection.failed or status == "slot_occupied" then
                    report(requestId, operation, false, status)
                    return
                end
            end
            Wait(100)
        end
        report(requestId, operation, false, "item_projection_timeout")
    end)
end

RegisterNetEvent("open77:helditem:request", function(requestId, operation, payload)
    if not validRequestId(requestId) or type(operation) ~= "string" then return end
    if type(payload) == "table" and payload.native == true then
        nativeRequest(requestId, operation, payload)
        return
    end
    local accepted, reason, result
    if operation == "hold" then
        accepted, reason, result = hold(payload)
    elseif operation == "release" then
        accepted, reason, result = release(payload)
    elseif operation == "snapshot" then
        local slots, failure = snapshot()
        accepted, reason, result = slots ~= nil, failure, slots
    else
        accepted, reason = false, "unsupported_operation"
    end
    report(requestId, operation, accepted, reason, result)
end)

-- A world entry rebuilds the body from the server's equipment record, which
-- knows nothing about held items. Forget what we thought we were holding rather
-- than reporting a stale slot: the registry read in `snapshot` stays truthful.
AddEventHandler("open77:equipment:ready", function() held = {} end)

exports("slots", function()
    local names = {}
    for name in pairs(SLOTS) do names[#names + 1] = name end
    table.sort(names)
    return names
end)
-- Exports follow the failure convention: true on success, false plus a reason
-- otherwise. The third return is the same result table the server is sent.
exports("hold", function(record, slot) return hold({ record = record, slot = slot or "WeaponRight" }) end)
exports("release", function(slot) return release({ slot = slot or "WeaponRight" }) end)
exports("snapshot", snapshot)
