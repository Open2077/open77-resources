-- /traffic.esp -- a debug overlay on the invoking client only: every nearby
-- replicated car's server vehicle id and physics owner ("o-" when none),
-- floated above the car. The client Lua host has no RegisterCommand, so the
-- server's restricted `traffic.esp` only relays the toggle to its caller.
--
-- Labels are native `render = "card"` anchors that follow the car's entity, so
-- the plugin moves them every frame; this loop only adds, relabels and removes
-- them. Whether an AI driver job is attached is server-side state the client
-- API does not expose, so the label does not claim it.
local RESOURCE = GetCurrentResourceName()
local ESP_TOGGLE = "open77_traffic:esp"
local RADIUS = 150
-- Open77.anchors' per-resource quota; `nearby` returns the nearest first.
local MAX_LABELS = 32
local REFRESH_MS = 250
-- `vehicles.get` copies the whole replica set per call, so owners come from
-- one `vehicles.all()` pass per second rather than one read per car per tick.
local OWNER_EVERY = 4

local enabled, loop = false, 0
local labels = {} -- vehicleId -> {anchor, entity, text, seen}
local query = { streamed = true, limit = MAX_LABELS }
local offset = { x = 0, y = 0, z = 1.8 }

local function report(text)
    TriggerEvent("chat:addMessage", { type = "system", author = "TRAFFIC", text = text })
end

local function clear()
    for id, label in pairs(labels) do
        Open77.anchors.remove(label.anchor)
        labels[id] = nil
    end
end

local function relabel()
    for _, car in ipairs(Open77.vehicles.all()) do
        local label = labels[car.id]
        if label then
            local owner = car.physicsOwner
            local text = owner ~= 0 and ("%d o%d"):format(car.id, owner) or ("%d o-"):format(car.id)
            if text ~= label.text and Open77.anchors.update(label.anchor, { presentation = { label = text } }) then
                label.text = text
            end
        end
    end
end

local function tick(pass)
    local cars, reason = Open77.vehicles.nearby(RADIUS, query)
    if type(cars) ~= "table" then
        clear()
        return reason
    end
    for _, car in ipairs(cars) do
        local label = labels[car.id]
        if label and label.entity == car.entity then label.seen = pass end
    end
    -- Free the quota before creating, or a car entering range waits a tick
    -- behind the one that left it.
    for id, label in pairs(labels) do
        if label.seen ~= pass then
            Open77.anchors.remove(label.anchor)
            labels[id] = nil
        end
    end
    local added, refusal = false, nil
    for _, car in ipairs(cars) do
        if not labels[car.id] and car.entity ~= 0 then
            local text = tostring(car.id)
            local anchor, why = Open77.anchors.create({
                entity = car.entity, offset = offset, render = "card", tag = "traffic.esp",
                maxDistance = RADIUS, presentation = { label = text },
            })
            if anchor then
                labels[car.id] = { anchor = anchor, entity = car.entity, text = text, seen = pass }
                added = true
            else
                refusal = why
            end
        end
    end
    if added or pass % OWNER_EVERY == 0 then relabel() end
    return refusal
end

local function stop()
    enabled = false
    loop = loop + 1
    clear()
end

RegisterNetEvent(ESP_TOGGLE, function()
    if enabled then
        stop()
        return report("traffic esp off")
    end
    enabled = true
    loop = loop + 1
    local mine = loop
    report(("traffic esp on: car id and owner within %d m, nearest %d"):format(RADIUS, MAX_LABELS))
    CreateThread(function()
        local pass, reported = 0, nil
        while loop == mine do
            pass = pass + 1
            local refusal = tick(pass)
            -- Once per distinct reason, not once per tick.
            if refusal and refusal ~= reported then
                reported = refusal
                report("traffic esp: " .. tostring(refusal))
            end
            Wait(REFRESH_MS)
        end
    end)
end)

AddEventHandler("onClientResourceStop", function(name)
    if name == RESOURCE then stop() end
end)
