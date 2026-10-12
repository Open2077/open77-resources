-- Slots and consumables come from the match ledger. Magazine/reserve and the
-- active slot come from the local engine's read-only weapon snapshot.
CordonInventory = {}
local inventory, matchId, participating = nil, nil, false
local sampled, pending = {}, {}
local requestedAt, sampledAt = -1, -1

local function now()
    return Open77.time and Open77.time.monotonic and Open77.time.monotonic() or 0
end

local function truth(value) return value == true or value == "true" end
local function weaponKey(value)
    local n = tonumber(value)
    return n and string.format("%.0f", n) or tostring(value or ""):lower()
end

function CordonInventory.adopt(state)
    local active = state.participant == true
    if state.matchId ~= matchId or active ~= participating then
        sampled, pending, requestedAt, sampledAt = {}, {}, -1, -1
    end
    participating, matchId = active, state.matchId
    inventory = active and type(state.inventory) == "table" and state.inventory or nil
end

function CordonInventory.poll()
    if not participating or not Open77.weapons or not Open77.weapons.snapshot then return end
    local at = now()
    if requestedAt >= 0 and at - requestedAt < 0.25 then return end
    requestedAt = at
    for key, request in pairs(pending) do
        if at - request.at > 2 then pending[key] = nil end
    end
    local ok, id = pcall(Open77.weapons.snapshot)
    if ok and id ~= nil then pending[tostring(id)] = { at = at, slots = {} } end
end

AddEventHandler("open77:weapons:state", function(requestId, slot, record, tweakDbId,
        active, drawn, locked, ammoRecord, ammoTweakDbId, ammoTotal, reserve, magazine, capacity)
    local request = pending[tostring(requestId)]
    local index = tonumber(slot)
    if not request or not index or index < 1 or index > 3 then return end
    request.slots[index] = {
        key = weaponKey(tweakDbId), record = tostring(record or ""),
        active = truth(active), drawn = truth(drawn),
        ammo = tonumber(magazine) or -1, reserve = tonumber(reserve) or -1,
    }
end)

AddEventHandler("open77:weapons:completed", function(requestId, operation, accepted)
    local key = tostring(requestId)
    local request = pending[key]
    pending[key] = nil
    if request and truth(accepted) and request.at >= sampledAt then
        -- Publish a complete snapshot, so switching weapons cannot briefly
        -- mark two slots active and a removed weapon cannot retain old ammo.
        sampled, sampledAt = request.slots, request.at
    end
end)

function CordonInventory.snapshot()
    if not inventory then return nil end
    local result = { plates = inventory.plates, heals = inventory.heals, slots = {} }
    for _, issued in ipairs(inventory.slots or {}) do
        local slot = tonumber(issued.slot)
        if slot and slot >= 1 and slot <= 3 then
            local actual = now() - sampledAt <= 2 and sampled[slot] or nil
            if actual and actual.key ~= weaponKey(issued.tweakDbId) then actual = nil end
            local label = issued.label
            if (not label or label == "") and actual then
                label = actual.record:match("^Items%.(.+)$")
                if label then
                    label = label:gsub("^Preset_", ""):gsub("_Default$", ""):gsub("_", " ")
                end
            end
            result.slots[#result.slots + 1] = {
                slot = slot, label = label or CordonHudStrings.inventory.weapon,
                active = actual ~= nil and actual.active,
                ammo = actual and actual.ammo or -1,
                reserve = actual and actual.reserve or -1,
            }
        end
    end
    return result
end
