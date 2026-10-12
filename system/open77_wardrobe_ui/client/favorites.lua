-- Persistent local preferences, independent from the PID-scoped CEF cache.
-- KVP supplies server/resource isolation. Identity is an additional key scope.
WardrobeFavorites = {}
local F = WardrobeFavorites
F.limit = 256
local slots = {Head=true,Face=true,InnerChest=true,OuterChest=true,Legs=true,Feet=true,Outfit=true}
function F.key(identity)
    local user = type(identity) == "table" and identity.userId
    if type(user) ~= "string" or #user ~= 36 then return nil, "identity_unavailable" end
    local a,b,c,d,e=user:match("^(%x+)%-(%x+)%-(%x+)%-(%x+)%-(%x+)$")
    if not a or #a~=8 or #b~=4 or #c~=4 or #d~=4 or #e~=12 then return nil, "identity_unavailable" end
    return "favorites.v1." .. user:lower()
end
function F.record(value, info)
    if type(value) ~= "string" or #value > 192 or not value:match("^Items%.[%w_]+$") then return nil end
    local item = info(value)
    if type(item) ~= "table" or item.defaultSelectable ~= true or item.nonvisual == true or not slots[item.slot]
        or (not item.supportsMale and not item.supportsFemale) then return nil end
    return item.record
end
function F.decode(text, info, yieldBatch)
    if text == nil then return {} end
    if type(text) ~= "string" or #text > F.limit * 193 then return nil, "invalid_favorites" end
    local records, scanned = {}, 0
    for entry in text:gmatch("[^\n]+") do
        scanned = scanned + 1
        if scanned > F.limit then return nil, "favorite_limit" end
        local record = F.record(entry, info)
        if record and not records[record] then records[record]=true end
        if yieldBatch and scanned % 32 == 0 then yieldBatch() end
    end
    return records
end
function F.encode(records)
    local values = {}
    for record in pairs(records) do values[#values+1]=record end
    if #values > F.limit then return nil, "favorite_limit" end
    table.sort(values)
    return table.concat(values, "\n")
end
function F.list(records)
    local values = {}
    for record in pairs(records) do values[#values+1]=record end
    table.sort(values)
    return values
end

-- CAS protects edits from another process using the same identity as well as
-- the store's native lock protecting different identity keys in the same file.
function F.update(kvp, key, record, enabled, info, yieldBatch, current)
    for _=1,4 do
        local stored, reason=kvp.get(key)
        if reason then return nil, reason end
        local values, decodeError=F.decode(stored,info,yieldBatch)
        if not values then return nil,decodeError end
        if current and not current() then return nil,"menu_closed" end
        values[record]=enabled and true or nil
        local encoded, encodeError=F.encode(values)
        if not encoded then return nil,encodeError end
        local exchanged, exchangeError=kvp.compareAndSet(key,stored,encoded)
        if exchanged then return values end
        if exchangeError then return nil,exchangeError end
        if yieldBatch then yieldBatch() end
    end
    return nil,"storage_busy"
end
