local page
local ready = false
local nextHandle = 1
local entries = {}
local identities = {}
local ownerGenerations = {}
local ownerEnabled = {}
local nextOwnerSweep = 0

local MAX_NOTIFICATIONS = 32
local MAX_PER_POSITION = 8
local FRAME_MS = 50
local positions = {
    top_left = true, top_center = true, top_right = true,
    middle_left = true,
    bottom_left = true, bottom_center = true, bottom_right = true,
}
-- Accent per notification kind. These are the OPEN//77 signal tokens, kept in
-- step with `web/open77-ui.css`: --op77-accent, --op77-ok, --op77-warn and
-- --op77-signal. Change them there and here together.
local kinds = {
    info = "#22D8E2",
    success = "#4FE3A9",
    warning = "#F5C95C",
    error = "#FF5964",
}

local function response(ok, values)
    values = values or {}
    values.ok = ok == true
    return values
end

local function finite(value)
    return type(value) == "number" and value == value and value > -math.huge and value < math.huge
end

local function validName(value, maximum)
    return type(value) == "string" and #value > 0 and #value <= maximum and
        value:match("^[%w_:%-%.]+$") ~= nil
end

local function validText(value, maximum, allowEmpty)
    return type(value) == "string" and #value <= maximum and
        (allowEmpty or #value > 0) and not value:find("[%c]")
end

local function normalizeColor(value, fallback)
    value = value or fallback
    if type(value) ~= "string" or not value:match(
        "^#[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]$") then
        return nil
    end
    return value:upper()
end

local function copy(source)
    local result = {}
    for key, value in pairs(source or {}) do result[key] = value end
    return result
end

local function normalize(owner, definition, handle)
    if type(definition) ~= "table" then return nil, "definition_must_be_a_table" end
    local kind = definition.type or definition.kind or "info"
    if type(kind) ~= "string" then return nil, "invalid_type" end
    kind = kind:lower()
    if not kinds[kind] then return nil, "invalid_type" end

    local id = definition.id or ("notification_" .. tostring(handle or nextHandle))
    local title = definition.title or ""
    local message = definition.message or definition.text
    local position = definition.position or "middle_left"
    local durationMs = definition.durationMs
    if durationMs == nil then durationMs = definition.duration end
    if durationMs == nil then durationMs = 5000 end
    local progress = definition.progress ~= false
    local color = normalizeColor(definition.color, kinds[kind])

    if not validName(id, 96) then return nil, "invalid_notification_id" end
    if not validText(title, 96, true) then return nil, "invalid_title" end
    if not validText(message, 384, false) then return nil, "invalid_message" end
    if not positions[position] then return nil, "invalid_position" end
    if not finite(durationMs) or durationMs % 1 ~= 0 or durationMs < 0 or durationMs > 120000 or
        (durationMs > 0 and durationMs < 750) then return nil, "invalid_duration" end
    if type(progress) ~= "boolean" then return nil, "invalid_progress" end
    if not color then return nil, "invalid_color" end
    if definition.icon ~= nil and not validText(definition.icon, 16, true) then return nil, "invalid_icon" end

    return {
        handle = handle,
        owner = owner,
        id = id,
        type = kind,
        title = title,
        message = message,
        icon = definition.icon or "",
        position = position,
        durationMs = durationMs,
        progress = progress and durationMs > 0,
        color = color,
        createdAt = Open77.time.monotonic(),
        expiresAt = durationMs > 0 and (Open77.time.monotonic() + durationMs / 1000) or nil,
        data = type(definition.data) == "table" and definition.data or {},
    }
end

local function payload(entry)
    return {
        handle = entry.handle,
        id = entry.id,
        type = entry.type,
        title = entry.title,
        message = entry.message,
        icon = entry.icon,
        position = entry.position,
        durationMs = entry.durationMs,
        progress = entry.progress,
        color = entry.color,
    }
end

local function send(action, value)
    if page and ready then page:send("notification:" .. action, value) end
end

local function removeInternal(handle, reason)
    local entry = entries[handle]
    if not entry then return false end
    identities[entry.owner .. ":" .. entry.id] = nil
    entries[handle] = nil
    send("remove", { handle = handle, reason = reason or "dismissed" })
    TriggerEvent("open77:notificationRemoved", {
        handle = handle, id = entry.id, owner = entry.owner, reason = reason or "dismissed",
        data = entry.data,
    })
    return true
end

local function removeOwner(owner, reason)
    local removed = 0
    for handle, entry in pairs(entries) do
        if entry.owner == owner and removeInternal(handle, reason or "owner_cleared") then
            removed = removed + 1
        end
    end
    return removed
end

local function evictPosition(position)
    local values = {}
    for _, entry in pairs(entries) do
        if entry.position == position then values[#values + 1] = entry end
    end
    if #values < MAX_PER_POSITION then return end
    table.sort(values, function(left, right) return left.createdAt < right.createdAt end)
    removeInternal(values[1].handle, "queue_limit")
end

local function showOwned(owner, definition)
    if ownerEnabled[owner] == false then return response(false, { error = "owner_disabled" }) end
    local existingId = type(definition) == "table" and definition.id or nil
    local existing = existingId and identities[owner .. ":" .. existingId] or nil
    if existing then
        if definition.replace ~= true then return response(false, { error = "duplicate_notification_id" }) end
        local current = entries[existing]
        local merged = copy(current)
        for key, value in pairs(definition) do merged[key] = value end
        local replacement, reason = normalize(owner, merged, existing)
        if not replacement then return response(false, { error = reason }) end
        entries[existing] = replacement
        send("update", payload(replacement))
        return response(true, { handle = existing, id = replacement.id, replaced = true })
    end

    local count = 0
    for _ in pairs(entries) do count = count + 1 end
    if count >= MAX_NOTIFICATIONS then return response(false, { error = "notification_limit" }) end
    local entry, reason = normalize(owner, definition)
    if not entry then return response(false, { error = reason }) end
    evictPosition(entry.position)
    entry.handle = nextHandle
    nextHandle = nextHandle + 1
    entries[entry.handle] = entry
    identities[owner .. ":" .. entry.id] = entry.handle
    send("add", payload(entry))
    return response(true, { handle = entry.handle, id = entry.id })
end

local function updateOwned(owner, handle, patch)
    handle = tonumber(handle)
    local current = handle and entries[handle] or nil
    if not current then return response(false, { error = "notification_not_found" }) end
    if current.owner ~= owner then return response(false, { error = "not_owner" }) end
    if type(patch) ~= "table" then return response(false, { error = "patch_must_be_a_table" }) end
    local merged = copy(current)
    for key, value in pairs(patch) do merged[key] = value end
    merged.id = current.id
    local replacement, reason = normalize(owner, merged, handle)
    if not replacement then return response(false, { error = reason }) end
    entries[handle] = replacement
    send("update", payload(replacement))
    return response(true, { handle = handle, id = replacement.id })
end

local function invokingOwner()
    local owner = GetInvokingResource()
    local generation = GetInvokingResourceGeneration()
    if not validName(owner, 64) or type(generation) ~= "number" then
        return nil, "export_call_required"
    end
    if ownerGenerations[owner] ~= nil and ownerGenerations[owner] ~= generation then
        removeOwner(owner, "owner_reloaded")
    end
    ownerGenerations[owner] = generation
    if ownerEnabled[owner] == nil then ownerEnabled[owner] = true end
    return owner
end

-- Observation only: consumers can fail closed rather than admit gameplay while
-- their mandatory warning surface is still loading. This is not rendered proof.
exports("readiness", function() return {ready=page~=nil and ready==true} end)

exports("show", function(definition)
    local owner, reason = invokingOwner()
    if not owner then return response(false, { error = reason }) end
    return showOwned(owner, definition)
end)

exports("update", function(handle, patch)
    local owner, reason = invokingOwner()
    if not owner then return response(false, { error = reason }) end
    return updateOwned(owner, handle, patch)
end)

exports("dismiss", function(handle)
    local owner, reason = invokingOwner()
    if not owner then return response(false, { error = reason }) end
    local entry = entries[tonumber(handle)]
    if not entry then return response(false, { error = "notification_not_found" }) end
    if entry.owner ~= owner then return response(false, { error = "not_owner" }) end
    removeInternal(entry.handle, "dismissed")
    return response(true)
end)

exports("clear", function()
    local owner, reason = invokingOwner()
    if not owner then return response(false, { error = reason }) end
    return response(true, { removed = removeOwner(owner, "owner_cleared") })
end)

exports("list", function()
    local owner = invokingOwner()
    if not owner then return {} end
    local result = {}
    for _, entry in pairs(entries) do
        if entry.owner == owner then result[#result + 1] = payload(entry) end
    end
    table.sort(result, function(left, right) return left.handle < right.handle end)
    return result
end)

exports("setEnabled", function(value)
    local owner, reason = invokingOwner()
    if not owner then return response(false, { error = reason }) end
    ownerEnabled[owner] = value ~= false
    if value == false then removeOwner(owner, "owner_disabled") end
    return response(true)
end)

exports("isEnabled", function()
    local owner = invokingOwner()
    return owner ~= nil and ownerEnabled[owner] ~= false
end)

local function serverOwner(value)
    if not validName(value, 64) then return nil end
    return "@server:" .. value
end

RegisterNetEvent("open77:notifications:show", function(envelope)
    if type(envelope) ~= "table" then return end
    local owner = serverOwner(envelope.owner)
    if not owner or not validName(envelope.id, 96) or type(envelope.definition) ~= "table" then return end
    local definition = copy(envelope.definition)
    definition.id = envelope.id
    definition.replace = true
    showOwned(owner, definition)
end)

RegisterNetEvent("open77:notifications:update", function(envelope)
    if type(envelope) ~= "table" then return end
    local owner = serverOwner(envelope.owner)
    local handle = owner and identities[owner .. ":" .. tostring(envelope.id)] or nil
    if handle and type(envelope.patch) == "table" then updateOwned(owner, handle, envelope.patch) end
end)

RegisterNetEvent("open77:notifications:dismiss", function(envelope)
    if type(envelope) ~= "table" then return end
    local owner = serverOwner(envelope.owner)
    local handle = owner and identities[owner .. ":" .. tostring(envelope.id)] or nil
    if handle then removeInternal(handle, "server_dismissed") end
end)

RegisterNetEvent("open77:notifications:clear", function(ownerName)
    local owner = serverOwner(ownerName)
    if owner then removeOwner(owner, "server_cleared") end
end)

local function sweepOwners()
    local now = Open77.time.monotonic()
    if now < nextOwnerSweep then return end
    nextOwnerSweep = now + 1
    for owner, generation in pairs(ownerGenerations) do
        if GetResourceState(owner) ~= "running" or Open77.resource.generation(owner) ~= generation then
            removeOwner(owner, "owner_stopped")
            ownerGenerations[owner] = nil
            ownerEnabled[owner] = nil
        end
    end
end

AddEventHandler("onClientResourceStart", function(name)
    if name ~= GetCurrentResourceName() then return end
    local reason
    page, reason = WebUI.create({
        entry = "web/index.html", layer = "hud", width = 1920, height = 1080,
        fps = 30, zIndex = 720, transparent = true, visible = true,
    })
    if not page then
        print("[open77_notifications] WebUI failed: " .. tostring(reason))
        return
    end
    page:on("notifications:ready", function()
        ready = true
        for _, entry in pairs(entries) do send("add", payload(entry)) end
    end)
    CreateThread(function()
        while page do
            local now = Open77.time.monotonic()
            local expired = {}
            for handle, entry in pairs(entries) do
                if entry.expiresAt and now >= entry.expiresAt then expired[#expired + 1] = handle end
            end
            for _, handle in ipairs(expired) do removeInternal(handle, "expired") end
            sweepOwners()
            Wait(FRAME_MS)
        end
    end)
end)

AddEventHandler("onClientResourceStop", function(name)
    if name == GetCurrentResourceName() then
        page, ready, entries, identities = nil, false, {}, {}
        ownerGenerations, ownerEnabled = {}, {}
    else
        removeOwner(name, "owner_stopped")
    end
end)
