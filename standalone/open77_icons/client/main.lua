-- Standalone, local presentation service. No framework, network events or WebUI.
-- Assets belong to this resource; consumer handles are scoped by caller + generation.
local names = Open77IconCatalogue
Open77IconCatalogue = nil
local known = {}
for _, name in ipairs(names) do known[name] = true end
local owned, generations = {}, {}
local MAX_PER_CALLER, MAX_TOTAL = 64, 128
local total = 0

local function normalize(name)
    if type(name) ~= "string" or #name > 100 then return nil end
    name = name:lower():gsub("^lucide:", "")
    if known[name] then return name end
end

local function forget(id)
    local ok, reason = Open77.blips.remove(id)
    -- A world teardown may already have removed the underlying native handle.
    owned[id] = nil
    total = total - 1
    return ok, reason
end

local function clearOwner(owner)
    local count = 0
    for id, entry in pairs(owned) do
        if entry.owner == owner then forget(id); count = count + 1 end
    end
    return count
end

local function caller()
    local owner, generation = GetInvokingResource(), GetInvokingResourceGeneration()
    if type(owner) ~= "string" or owner == "" or type(generation) ~= "number" then
        return nil, "export_call_required"
    end
    if generations[owner] and generations[owner] ~= generation then clearOwner(owner) end
    generations[owner] = generation
    return owner
end

local function entryFor(id)
    local owner, reason = caller()
    if not owner then return nil, reason end
    local entry = type(id) == "string" and owned[id]
    if not entry or entry.owner ~= owner then return nil, "blip_not_owned" end
    return entry
end

local allowed = { position=true, entity=true, sprite=true, title=true, description=true,
    label=true, active=true, visibleThroughWalls=true, range=true, routable=true,
    slot=true, offset=true, color=true, icon=true, size=true }

local function options(input, current)
    if type(input) ~= "table" then return nil, "invalid_options" end
    local result = {}
    for key, value in pairs(input) do
        if not allowed[key] then return nil, "unsupported_option:" .. tostring(key) end
        if current and key == "routable" then return nil, "routable_is_create_only" end
        if key ~= "icon" and key ~= "size" then result[key] = value end
    end
    local name, size = current and current.icon, current and current.size or 48
    if input.size ~= nil then
        if type(input.size) ~= "number" or input.size ~= input.size or input.size < 16 or input.size > 128 then
            return nil, "invalid_icon_size"
        end
        size = input.size
    end
    if input.icon == false and current then name = false
    elseif input.icon ~= nil then
        name = normalize(input.icon)
        if not name then return nil, "unknown_icon" end
    elseif not current then return nil, "icon_required" end
    if input.icon ~= nil or input.size ~= nil or not current then
        if name then result.icon = { asset="icons/lucide/" .. name .. ".svg", size=size }
        else result.icon = false end
    end
    return result, nil, name, size
end

exports("info", function()
    return { library="Lucide", version="1.47.0", count=#names, runtime="client",
        apiAvailable=type(Open77.blips.setColor) == "function",
        maximumPerCaller=MAX_PER_CALLER, maximumTotal=MAX_TOTAL }
end)

exports("has", function(name) return normalize(name) ~= nil end)

exports("list", function(query, offset, limit)
    query, offset, limit = query or "", offset or 0, limit or 50
    if type(query) ~= "string" or #query > 80 then return nil, "invalid_query" end
    if type(offset) ~= "number" or offset < 0 or offset % 1 ~= 0 or offset > #names then return nil, "invalid_offset" end
    if type(limit) ~= "number" or limit < 1 or limit > 100 or limit % 1 ~= 0 then return nil, "invalid_limit" end
    query = query:lower():gsub("^lucide:", "")
    local found, count = {}, 0
    for _, name in ipairs(names) do
        if name:find(query, 1, true) then
            count = count + 1
            if count > offset and #found < limit then found[#found + 1] = name end
        end
    end
    return { icons=found, total=count, offset=offset, limit=limit }
end)

exports("create", function(input)
    local owner, reason = caller()
    if not owner then return nil, reason end
    if type(Open77.blips.setColor) ~= "function" then return nil, "svg_client_required" end
    local count = 0
    for _, entry in pairs(owned) do if entry.owner == owner then count = count + 1 end end
    if count >= MAX_PER_CALLER or total >= MAX_TOTAL then return nil, "icon_blip_limit" end
    local definition, err, name, size = options(input)
    if not definition then return nil, err end
    if definition.sprite == nil then definition.sprite = "tech" end
    local id, why = Open77.blips.create(definition)
    if not id then return nil, why end
    owned[id] = { owner=owner, icon=name, size=size }
    total = total + 1
    return id
end)

local function update(id, patch)
    local entry, reason = entryFor(id)
    if not entry then return false, reason end
    local definition, err, name, size = options(patch, entry)
    if not definition then return false, err end
    local ok, why = Open77.blips.update(id, definition)
    if ok then entry.icon, entry.size = name, size end
    return ok, why
end
exports("update", update)
exports("setIcon", function(id, name, size)
    if name == nil then return false, "icon_required" end
    return update(id, { icon=name, size=size })
end)
exports("setColor", function(id, color)
    if color == nil then return false, "invalid_color" end
    return update(id, { color=color })
end)
exports("setPosition", function(id, position)
    if type(position) ~= "table" then return false, "invalid_position" end
    return update(id, { position=position })
end)
exports("setActive", function(id, active)
    if type(active) ~= "boolean" then return false, "invalid_active" end
    return update(id, { active=active })
end)
exports("setRange", function(id, range)
    if range == nil then return false, "invalid_range" end
    return update(id, { range=range })
end)

for _, method in ipairs({ "track", "untrack", "get" }) do
    exports(method, function(id)
        local entry, reason = entryFor(id)
        if not entry then return nil, reason end
        return Open77.blips[method](id)
    end)
end
exports("remove", function(id)
    local entry, reason = entryFor(id)
    if not entry then return false, reason end
    return forget(id)
end)
exports("clear", function()
    local owner, reason = caller()
    if not owner then return nil, reason end
    return clearOwner(owner)
end)

AddEventHandler("onClientResourceStop", function(name)
    if name == GetCurrentResourceName() then
        for id in pairs(owned) do forget(id) end
        return
    end
    clearOwner(name)
    generations[name] = nil
end)

-- Stop events may be local to a resource VM. Generation checks close that gap.
CreateThread(function()
    while true do
        Wait(1000)
        for owner, generation in pairs(generations) do
            if GetResourceState(owner) ~= "running" or Open77.resource.generation(owner) ~= generation then
                clearOwner(owner)
                generations[owner] = nil
            end
        end
    end
end)
