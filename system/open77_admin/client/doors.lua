-- Native cards are projected and drawn in the presenting frame. Lua only reads
-- bounded nearby state twice per second; no CEF surface, frame RPC or door write.
local RESOURCE, COMMAND = GetCurrentResourceName(), "admin.dev.doors.inspect"
local RADIUS, LIMIT, LEASE = 25, 8, 3.5
local D, A = Open77.doors, Open77.anchors
local available = type(D) == "table" and type(D.near) == "function"
    and type(A) == "table" and type(A.create) == "function"
    and type(A.update) == "function" and type(A.remove) == "function"
local enabled, expires, generation, stopped = false, 0, 0, false
local cards, count, nearby, issue = {}, 0, 0, nil
local lastNotice = ""

local function notify()
    local text = tostring(enabled) .. ":" .. count .. ":" .. nearby .. ":" .. tostring(issue)
    if text ~= lastNotice then
        lastNotice = text
        TriggerEvent("open77_admin:doorInspectorChanged")
    end
end
local function clear()
    for _, card in pairs(cards) do A.remove(card.id) end
    cards, count, nearby = {}, 0, 0
end
local function disable()
    enabled, expires, generation = false, 0, generation + 1
    clear()
    notify()
end
Open77AdminDoorInspector = {
    state = function()
        return { enabled = enabled, available = available, count = count,
            nearby = nearby, radius = RADIUS, limit = LIMIT, error = issue }
    end,
}

local function finite(n)
    return type(n) == "number" and n == n and n > -math.huge and n < math.huge
end
local function valid(d)
    return type(d) == "table" and type(d.id) == "string" and #d.id <= 20
        and d.id:match("^0x%x+$") and type(d.position) == "table"
        and finite(d.position.x) and finite(d.position.y) and finite(d.position.z)
        and finite(d.distance) and d.distance >= 0 and d.distance <= RADIUS
end
local function stateText(d)
    return (d.open and "OPEN" or "CLOSED") .. (d.locked and " / LOCKED" or "")
        .. (d.sealed and " / SEALED" or "")
end
local function presentation(d, target, service)
    local mismatch = target and (d.open ~= target.open or d.locked ~= target.locked or d.sealed ~= target.sealed)
    local accent = mismatch and "#FFB547" or not target and "#8795A5"
        or (d.locked or d.sealed) and "#FF5064" or d.open and "#45DCA6" or "#19CCD9"
    local sub = not service and "SERVER: unavailable (native only)"
        or not target and "SERVER: not in interest / awaiting discovery"
        or ("SERVER: " .. stateText(target) .. " | B" .. tostring(target.bucket)
            .. " R" .. tostring(target.revision) .. (target.automatic and " AUTO" or " MANUAL"))
    if target and target.lift then
        sub = sub .. " | LIFT " .. tostring(target.elevatorId) .. ":F" .. tostring(target.elevatorFloor)
    end
    return { label = d.id .. " | LOCAL: " .. stateText(d), sublabel = sub,
        color = "#F0F4F8", accent = accent, background = "#0B111B",
        scale = 0.75, showDistance = true }
end
local function targetState(id)
    if not Open77.exports or GetResourceState("open77_doors") ~= "running" then return nil, false end
    local pending = Open77.exports.call("open77_doors", "get", id)
    if not pending then return nil, false end
    local value, reason = pending:await()
    return type(value) == "table" and value or nil, reason == nil
end
local function refresh()
    local token = generation
    local list, reason = D.near(RADIUS)
    if type(list) ~= "table" then
        clear(); issue = tostring(reason or "Door state unavailable"); notify(); return
    end
    -- Native results are nearest-first; retain only live, bounded descriptors.
    local chosen, keep = {}, {}
    nearby = 0
    for _, d in ipairs(list) do
        if valid(d) and not keep[d.id] then
            nearby = nearby + 1
            if #chosen < LIMIT then chosen[#chosen + 1], keep[d.id] = d, true end
        end
    end
    for id, card in pairs(cards) do
        if not keep[id] then A.remove(card.id); cards[id] = nil end
    end
    issue = nil
    for _, d in ipairs(chosen) do
        local target, service = targetState(d.id)
        -- An awaited export may resume after OFF, revocation or a world change.
        if stopped or not enabled or token ~= generation or Open77.time.monotonic() >= expires then return end
        local style = presentation(d, target, service)
        local position = { x = d.position.x, y = d.position.y, z = d.position.z + 1.5 }
        local signature = style.label .. style.sublabel .. style.accent
            .. string.format(":%.3f:%.3f:%.3f:%s", position.x, position.y, position.z, tostring(d.networkInstance))
        local card = cards[d.id]
        if card and card.signature ~= signature then
            local ok, error = A.update(card.id, { position = position, presentation = style })
            if ok then card.signature = signature
            else A.remove(card.id); cards[d.id] = nil; issue = tostring(error) end
        end
        if not cards[d.id] then
            local anchor, error = A.create({ position = position, render = "card",
                tag = "admin:door:" .. d.id, maxDistance = RADIUS + 8,
                presentation = style })
            if anchor then cards[d.id] = { id = anchor, signature = signature }
            else issue = tostring(error or "No native anchor available") end
        end
    end
    count = 0; for _ in pairs(cards) do count = count + 1 end
    notify()
end

RegisterNetEvent("open77_admin:data", function(channel, payload)
    if type(payload) ~= "table" then return end
    if channel == "doorInspector" then
        if payload.enabled ~= true then disable(); return end
        if not available then issue = "Client update required for native door labels"; notify(); return end
        expires = Open77.time.monotonic() + LEASE
        if not enabled then enabled = true; generation = generation + 1; issue = nil; notify() end
    elseif channel == "access" and not (payload.commands and payload.commands[COMMAND] == true) then
        disable()
    end
end)
AddEventHandler("open77:worldReady", disable)
local function stop(name)
    if name ~= RESOURCE then return end
    stopped = true; disable()
end
AddEventHandler("onClientResourceStop", stop)
AddEventHandler("onResourceStop", stop)
CreateThread(function()
    while not stopped do
        if enabled then
            if Open77.time.monotonic() >= expires then disable()
            else refresh() end
        end
        Wait(500)
    end
end)
