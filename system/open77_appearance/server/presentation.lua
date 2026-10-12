-- All three presentation records share this VM and its authenticated character
-- selection. Client resources remain independent; no cross-resource Lua exports.
Presentation = { characters = {}, families = {}, records = {}, epochs = {} }
local P = Presentation
-- Match native presence, including the owner. A global Lua broadcast bypasses
-- distance/bucket culling and recreates the full-world join burst.
function P.inScope(viewer, player)
    return Open77.players.isInScope(viewer, player) == true
end
function P.sendToObservers(event, player, ...)
    for _, viewer in ipairs(Open77.players.observers(player)) do
        TriggerClientEvent(event, viewer, player, ...)
    end
end
local database = "starting"
local queues = {}
local lastRequest = {}
local lastUiRequest = {}
local cyberwareBound = {}
local restoreOwner

local function bindCyberware(player, character)
    -- The optional support resource must be running. Its presence does not
    -- grant an implant: this only selects the authenticated durable character.
    if GetResourceState("open77_cyberware") ~= "running" then return end
    local ok, reason = Open77.cyberware.bind(player, character or "default")
    if ok then cyberwareBound[player] = true
    elseif reason ~= "cyberware_storage_unavailable" then
        print("[open77_presentation] cyberware identity unavailable: " .. tostring(reason))
    end
end
local slots = { Head=true, Face=true, InnerChest=true, OuterChest=true, Legs=true,
    Feet=true, Outfit=true, UnderwearTop=true, UnderwearBottom=true }
local defaults = { Head=false, Face=false, InnerChest=false, OuterChest=false,
    Legs=false, Feet=false, Outfit=false, UnderwearTop=false,
    UnderwearBottom="Items.Underwear_Basic_01_Bottom" }

local function copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, item in pairs(value) do result[key] = copy(item) end
    return result
end

local function outfitIndex(value)
    return type(value) == "number" and value % 1 == 0 and value >= 0 and value < 7
end

-- The same audited 2.31 catalogue as the native API. Normalize names and hash
-- spellings to one identity before comparison, validation and persistence.
local function item(slot, value, family)
    if not slots[slot] then return nil end
    if value == false or value == nil then return false end
    if type(value) ~= "string" then return nil end
    local entry = PresentationCatalog[value] or PresentationCatalog[string.lower(value)]
    if not entry or entry.slot ~= slot then return nil end
    local mask = family == "male" and 1 or 2
    if entry.flags & mask == 0 or entry.flags & 4 == 0 then return nil end
    return entry.record
end

local function slotSet(value, family, wardrobe)
    if type(value) ~= "table" then return nil end
    local clean, count = {}, 0
    for slot, record in pairs(value) do
        count = count + 1
        if count > 9 or not slots[slot] or (wardrobe and slot:match("^Underwear")) then return nil end
        local resolved = item(slot, record, family)
        if resolved == nil then return nil end
        clean[slot] = resolved
    end
    return clean
end

local function identity(player)
    return GetPlayerIdentifier(player), P.characters[player] or "default", P.epochs[player] or 0
end

local function current(player, user, character, epoch)
    local u, c, e = identity(player)
    return u == user and c == character and e == epoch
end

-- Serialize database work per player. Capture identity before yielding, and
-- discard stale completions after disconnect, reload or character selection.
function P.enqueue(player, action)
    if type(player) ~= "number" or player <= 0 then return false end
    local user, character, epoch = identity(player)
    if type(user) ~= "string" or #user ~= 36 then return false end
    local queue = queues[player]
    if queue then
        if #queue >= 64 then return false end
        queue[#queue + 1] = { action, user, character, epoch }
        return true
    end
    queue = { { action, user, character, epoch } }
    queues[player] = queue
    CreateThread(function()
        while #queue > 0 do
            local next = table.remove(queue, 1)
            if current(player, next[2], next[3], next[4]) then
                local ok, reason = pcall(next[1], next[2], next[3], next[4])
                if not ok then
                    Wait(0) -- A quota error has exhausted this tick's instruction budget.
                    print("[open77_presentation] operation failed: " .. tostring(reason))
                    if current(player, next[2], next[3], next[4]) then
                        TriggerClientEvent("open77:presentation:error", player, "presentation_database_error")
                        -- Roll back the owner's optimistic visuals to the last
                        -- committed record, without retrying a failed load.
                        -- Do not enqueue the failed ready operation again. A quota
                        -- failure would otherwise retry forever in this same tick.
                        if P.records[player] then
                            local restored, failure = pcall(restoreOwner, player)
                            if not restored then print("[open77_presentation] rollback failed: " .. tostring(failure)) end
                        end
                    end
                end
            end
            Wait(0)
        end
        if queues[player] == queue then queues[player] = nil end
    end)
    return true
end

function P.select(player, character)
    if cyberwareBound[player] then
        Open77.cyberware.unbind(player)
        cyberwareBound[player] = nil
    end
    P.epochs[player] = (P.epochs[player] or 0) + 1
    P.characters[player] = character
    P.records[player] = nil
end

local function revision(record)
    return record and tonumber(record.wardrobe.revision) or 0
end

local function validName(value)
    if type(value) ~= "string" or #value > 192 or value:find("[%z\1-\31\127]") then return false end
    local length = utf8.len(value)
    return length ~= nil and length >= 1 and length <= 48 and value:match("%S") ~= nil
end

local function load(player, user, character, epoch)
    while database == "starting" do Wait(0) end
    if not current(player, user, character, epoch) then return nil end
    if P.records[player] then return P.records[player] end
    if database == "failed" then error("presentation_database_unavailable") end
    local record = { equipment=copy(defaults), wardrobe={ outfits={} } }
    if database == "ready" then
        local row = MySQL.single.await([[
            SELECT equipment_json, wardrobe_json FROM open77_character_presentation
            WHERE user_id=@user AND character_key=@character
        ]], { user=user, character=character })
        if not current(player, user, character, epoch) then return nil end
        if row then
            local eq = json.decode(row.equipment_json)
            local wardrobe = json.decode(row.wardrobe_json)
            -- Preserve incompatible-family items in storage: their compatible
            -- visuals are chosen below, a temporary body swap never deletes them.
            if type(eq) ~= "table" or type(wardrobe) ~= "table" or type(wardrobe.outfits) ~= "table" then
                error("invalid_stored_presentation")
            end
            local function validateStoredSet(values, overlay)
                if type(values) ~= "table" then error("invalid_stored_slots") end
                for slot, value in pairs(values) do
                    if not slots[slot] or (overlay and slot:match("^Underwear"))
                        or (item(slot, value, "male") == nil and item(slot, value, "female") == nil) then
                        error("invalid_stored_item")
                    end
                end
            end
            validateStoredSet(eq, false)
            if wardrobe.active ~= nil and not outfitIndex(wardrobe.active) then error("invalid_stored_outfit") end
            for index, values in pairs(wardrobe.outfits) do
                if not outfitIndex(tonumber(index)) then error("invalid_stored_outfit") end
                validateStoredSet(values, true)
            end
            if wardrobe.revision ~= nil and (type(wardrobe.revision) ~= "number"
                or wardrobe.revision % 1 ~= 0 or wardrobe.revision < 0 or wardrobe.revision > 9007199254740990) then
                error("invalid_stored_revision")
            end
            if wardrobe.names ~= nil then
                if type(wardrobe.names) ~= "table" then error("invalid_stored_names") end
                for index, name in pairs(wardrobe.names) do
                    if not outfitIndex(tonumber(index)) or not validName(name) then error("invalid_stored_name") end
                end
            end
            record = { equipment=eq, wardrobe=wardrobe }
        end
    end
    P.records[player] = record
    return record
end

local function save(player, user, character, epoch, record)
    record.wardrobe.revision = revision(P.records[player]) + 1
    if database == "ready" then
        MySQL.update.await([[
            INSERT INTO open77_character_presentation (user_id, character_key, equipment_json, wardrobe_json)
            VALUES (@user, @character, @equipment, @wardrobe)
            ON DUPLICATE KEY UPDATE equipment_json=VALUES(equipment_json), wardrobe_json=VALUES(wardrobe_json)
        ]], { user=user, character=character, equipment=json.encode(record.equipment), wardrobe=json.encode(record.wardrobe) })
    elseif database ~= "disabled" then error("presentation_database_unavailable") end
    if not current(player, user, character, epoch) then return false end
    P.records[player] = record
    return true
end

local function visible(player, record)
    local result = { equipment={}, wardrobe={ active=record.wardrobe.active, outfits={}, names=copy(record.wardrobe.names or {}) } }
    for slot in pairs(slots) do
        result.equipment[slot] = item(slot, record.equipment[slot], P.families[player]) or false
    end
    for index, outfit in pairs(record.wardrobe.outfits) do
        local shown = {}
        for slot, value in pairs(outfit) do
            if slots[slot] and not slot:match("^Underwear") then
                shown[slot] = item(slot, value, P.families[player]) or false
            end
        end
        result.wardrobe.outfits[tostring(index)] = shown
    end
    return result
end

local function broadcast(player, record)
    local shown = visible(player, record)
    P.sendToObservers("open77:equipment:record", player, shown.equipment)
    P.sendToObservers("open77:wardrobe:record", player, shown.wardrobe)
end

restoreOwner = function(player)
    local shown = visible(player, P.records[player])
    TriggerClientEvent("open77:equipment:self", player, shown.equipment)
    TriggerClientEvent("open77:wardrobe:self", player, shown.wardrobe)
end

-- Observer-only replay from the committed session cache. A routing transition
-- must not reload SQL, overwrite the owner's preview, or invent an empty look
-- while character/bootstrap work is still in flight. The caller scopes peers.
function P.sendRecords(viewer, player)
    if not P.inScope(viewer, player) then return end
    local record = P.records[player]
    if not record then return end
    local shown = visible(player, record)
    TriggerClientEvent("open77:equipment:record", viewer, player, shown.equipment)
    TriggerClientEvent("open77:wardrobe:record", viewer, player, shown.wardrobe)
end

function P.ready(player)
    P.enqueue(player, function(user, character, epoch)
        local record = load(player, user, character, epoch)
        if not record then return end
        bindCyberware(player, character)
        local shown = visible(player, record)
        TriggerClientEvent("open77:equipment:me", player, player)
        TriggerClientEvent("open77:wardrobe:me", player, player)
        TriggerClientEvent("open77:equipment:self", player, shown.equipment)
        TriggerClientEvent("open77:wardrobe:self", player, shown.wardrobe)
        for _, other in ipairs(Open77.players.inScope(player)) do
            local state = P.records[other]
            if other ~= player and state then
                local otherShown = visible(other, state)
                TriggerClientEvent("open77:equipment:record", player, other, otherShown.equipment)
                TriggerClientEvent("open77:wardrobe:record", player, other, otherShown.wardrobe)
            end
        end
        broadcast(player, record)
    end)
end

-- Menu transactions never publish a preview. The owner commits explicit edits
-- once, with optimistic concurrency; unchanged incompatible items stay stored.
local function uiState(player)
    local record = P.records[player]
    if not record then return { available=false, error="presentation_not_ready" } end
    local state = visible(player, record)
    state.available = true
    state.revision = revision(record)
    state.characterKey = P.characters[player] or "default"
    state.family = P.families[player] or "female"
    state.persistence = database
    state.incompatible = { equipment={}, outfits={} }
    for slot, value in pairs(record.equipment) do
        if value and item(slot, value, state.family) == nil then state.incompatible.equipment[slot] = true end
    end
    for index, outfit in pairs(record.wardrobe.outfits) do
        for slot, value in pairs(outfit) do
            if value and item(slot, value, state.family) == nil then
                state.incompatible.outfits[tostring(index)] = true
            end
        end
    end
    -- false is explicit over JSON/Lua transport, unlike omitted nil.
    state.wardrobe.active = state.wardrobe.active or false
    return state
end

RegisterNetEvent("open77:presentation:uiRequest", function()
    local player = tonumber(source)
    if not player then return end
    local now = GetGameTimer()
    if now - (lastUiRequest[player] or -250) < 250 then return end
    lastUiRequest[player] = now
    TriggerClientEvent("open77:presentation:uiState", player, uiState(player))
end)

RegisterCommand("wardrobe", function(player)
    if player and player > 0 then TriggerClientEvent("open77:wardrobe_ui:open", player) end
end, false)

local function patchRecord(player, record, patch)
    if type(patch) ~= "table" then return nil, "invalid_patch" end
    for key in pairs(patch) do
        if key ~= "expectedRevision" and key ~= "characterKey" and key ~= "equipment" and key ~= "wardrobe" then
            return nil, "invalid_patch_field"
        end
    end
    if patch.characterKey ~= (P.characters[player] or "default") then return nil, "character_changed" end
    if type(patch.expectedRevision) ~= "number" or patch.expectedRevision ~= revision(record) then
        return nil, "revision_conflict"
    end
    local result = copy(record)
    if patch.equipment ~= nil then
        local equipment = slotSet(patch.equipment, P.families[player], false)
        if not equipment then return nil, "invalid_equipment" end
        for slot, value in pairs(equipment) do result.equipment[slot] = value end
    end
    if patch.wardrobe ~= nil then
        if type(patch.wardrobe) ~= "table" then return nil, "invalid_wardrobe" end
        for key in pairs(patch.wardrobe) do
            if key ~= "active" and key ~= "outfits" and key ~= "names" then return nil, "invalid_wardrobe_field" end
        end
        if patch.wardrobe.active ~= nil then
            if patch.wardrobe.active ~= false and not outfitIndex(patch.wardrobe.active) then return nil, "invalid_outfit" end
            result.wardrobe.active = patch.wardrobe.active ~= false and patch.wardrobe.active or nil
        end
        if patch.wardrobe.outfits ~= nil then
            if type(patch.wardrobe.outfits) ~= "table" then return nil, "invalid_outfits" end
            local count, seen = 0, {}
            for index, outfit in pairs(patch.wardrobe.outfits) do
                count = count + 1
                local number = tonumber(index)
                if count > 7 or not outfitIndex(number) or seen[number] then return nil, "invalid_outfit" end
                seen[number] = true
                local clean = slotSet(outfit, P.families[player], true)
                if not clean then return nil, "invalid_outfit_items" end
                result.wardrobe.outfits[tostring(number)] = clean
                result.wardrobe.outfits[number] = nil
            end
        end
        if patch.wardrobe.names ~= nil then
            if type(patch.wardrobe.names) ~= "table" then return nil, "invalid_names" end
            result.wardrobe.names = result.wardrobe.names or {}
            local count, seen = 0, {}
            for index, name in pairs(patch.wardrobe.names) do
                count = count + 1
                local number = tonumber(index)
                if count > 7 or not outfitIndex(number) or seen[number] or not validName(name) then return nil, "invalid_name" end
                seen[number] = true
                result.wardrobe.names[tostring(number)] = name
                result.wardrobe.names[number] = nil
            end
        end
    end
    return result
end

RegisterNetEvent("open77:presentation:commit", function(request, patch)
    local player = tonumber(source)
    if not player or type(request) ~= "string" or #request < 1 or #request > 96 then return end
    local function reply(ok, reason)
        TriggerClientEvent("open77:presentation:commitResult", player, request, ok, reason or "", uiState(player))
    end
    if not P.records[player] then reply(false, "presentation_not_ready"); return end
    local queued = P.enqueue(player, function(user, character, epoch)
        local ok, accepted, reason = pcall(function()
            local original = load(player, user, character, epoch)
            if not original then return false, "character_changed" end
            local record, invalid = patchRecord(player, original, patch)
            if not record then return false, invalid end
            if not save(player, user, character, epoch, record) then return false, "character_changed" end
            local shown = visible(player, record)
            TriggerClientEvent("open77:equipment:self", player, shown.equipment)
            TriggerClientEvent("open77:wardrobe:self", player, shown.wardrobe)
            broadcast(player, record)
            return true
        end)
        if not current(player, user, character, epoch) then return end
        if not ok then
            print("[open77_presentation] menu commit failed: " .. tostring(accepted))
            reply(false, "presentation_database_error")
        else reply(accepted, reason) end
    end)
    if not queued then reply(false, "presentation_busy") end
end)

RegisterNetEvent("open77:session:gameplayReady", function() P.ready(tonumber(source)) end)
RegisterNetEvent("open77:presentation:request", function()
    local player = tonumber(source)
    if not player or GetGameTimer() - (lastRequest[player] or -1000) < 1000 then return end
    lastRequest[player] = GetGameTimer()
    P.ready(player)
end)

RegisterNetEvent("open77:equipment:slot", function(slot, value)
    local player = tonumber(source)
    if not player or not P.records[player] then return end
    local resolved = item(slot, value, P.families[player])
    if resolved == nil then
        TriggerClientEvent("open77:equipment:self", player, visible(player, P.records[player]).equipment)
        return
    end
    P.enqueue(player, function(user, character, epoch)
        local record = load(player, user, character, epoch)
        if not record then return end
        if record.equipment[slot] ~= resolved then
            record = copy(record)
            record.equipment[slot] = resolved
            if not save(player, user, character, epoch, record) then return end
        end
        P.sendToObservers("open77:equipment:slot", player, slot, resolved)
    end)
end)

RegisterNetEvent("open77:wardrobe:active", function(active)
    local player = tonumber(source)
    if not player or not P.records[player] or (active ~= nil and not outfitIndex(active)) then return end
    P.enqueue(player, function(user, character, epoch)
        local record = load(player, user, character, epoch)
        if not record then return end
        record = copy(record)
        record.wardrobe.active = active
        if save(player, user, character, epoch, record) then broadcast(player, record) end
    end)
end)

RegisterNetEvent("open77:wardrobe:outfit", function(index, values)
    local player = tonumber(source)
    if not player or not P.records[player] or not outfitIndex(index) then return end
    local clean = slotSet(values, P.families[player], true)
    if not clean then
        TriggerClientEvent("open77:wardrobe:self", player, visible(player, P.records[player]).wardrobe)
        return
    end
    P.enqueue(player, function(user, character, epoch)
        local record = load(player, user, character, epoch)
        if not record then return end
        record = copy(record)
        -- JSON object keys are strings after a database round trip.
        record.wardrobe.outfits[tostring(index)] = clean
        record.wardrobe.outfits[index] = nil
        if save(player, user, character, epoch, record) then broadcast(player, record) end
    end)
end)

AddEventHandler("playerDropped", function()
    local player = tonumber(source)
    if not player then return end
    P.select(player, nil)
    P.families[player] = nil
    lastRequest[player] = nil
    lastUiRequest[player] = nil
end)

-- Host notifications run after the state transition and cross VM boundaries;
-- onResourceStart/onResourceStop describe only this resource's own VM.
local cyberwareLifecycle = 0
local function cyberwareLifecycleChanged(name, revision)
    revision = tonumber(revision)
    if name ~= "open77_cyberware" or not revision or revision <= cyberwareLifecycle then return end
    cyberwareLifecycle = revision
    -- Lua tasks due on the same tick may run in reverse scheduling order.
    -- Reconcile the newest transition against current host state, so a queued
    -- old stop cannot erase a binding created by a later start/reload.
    for player in pairs(cyberwareBound) do Open77.cyberware.unbind(player) end
    cyberwareBound = {}
    if GetResourceState(name) == "running" then
        for player in pairs(P.records) do bindCyberware(player, P.characters[player]) end
    end
end
AddEventHandler("open77:resource:started", cyberwareLifecycleChanged)
AddEventHandler("open77:resource:stopped", cyberwareLifecycleChanged)

CreateThread(function()
    local ok, reason = pcall(function()
        MySQL.update.await([[
            CREATE TABLE IF NOT EXISTS open77_character_presentation (
                user_id CHAR(36) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
                character_key VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
                equipment_json LONGTEXT NOT NULL, wardrobe_json LONGTEXT NOT NULL,
                updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
                PRIMARY KEY (user_id, character_key)
            ) ENGINE=InnoDB
        ]])
    end)
    database = ok and "ready" or (tostring(reason):find("database_unavailable", 1, true) and "disabled" or "failed")
    print("[open77_presentation] database=" .. database)
end)
