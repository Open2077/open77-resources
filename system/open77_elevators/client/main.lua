-- Client resources get streamed read-only snapshots. Durable state and native
-- movement remain server-authoritative; request() only submits player intent.
if type(Open77.elevators) ~= "table" then
    print("[open77_elevators] native elevator API unavailable; restart Cyberpunk")
    return
end

local revisions = {}
local announced = {}

local function announceNearby()
    local now = Open77.time.monotonic()
    for _, lift in ipairs(Open77.elevators.nearby(80.0)) do
        -- Topology is filled asynchronously by elevator.inspect. Never invent
        -- a floor count: wait until the native LiftDevicePS has answered.
        if not lift.managed and lift.floorCount and lift.floorCount > 0 and
            lift.activeFloor and lift.activeFloor >= 0 and
            (announced[lift.engineEntity] == nil or now - announced[lift.engineEntity] >= 5.0) then
            announced[lift.engineEntity] = now
            local position = lift.position or {}
            local accepted, reason = TriggerServerEvent("open77:elevator:discover",
                lift.engineEntity, position.x, position.y, position.z,
                lift.floorCount, lift.activeFloor)
            if not accepted then
                print(string.format("[open77_elevators] discovery queue failed for %s: %s",
                    tostring(lift.engineEntity), tostring(reason)))
            end
        end
    end
end

CreateThread(function()
    while true do
        announceNearby()
        local current = {}
        for _, lift in ipairs(Open77.elevators.all()) do
            current[lift.id] = lift.revision
            if revisions[lift.id] == nil then
                TriggerEvent("open77:elevator:streamedIn", lift.id, lift)
            elseif revisions[lift.id] ~= lift.revision then
                TriggerEvent("open77:elevator:updated", lift.id, lift)
            end
        end
        for id in pairs(revisions) do
            if current[id] == nil then TriggerEvent("open77:elevator:streamedOut", id) end
        end
        revisions = current
        Wait(500)
    end
end)

RegisterNetEvent("open77:elevator:discovered", function(engineEntity, id)
    -- The authoritative ElevatorState normally arrives on the same reliable
    -- channel immediately afterwards. Keep retry suppression here so a slow
    -- frame cannot enqueue duplicate discovery events before that state maps
    -- the native entity to its Open77 ID.
    announced[tostring(engineEntity)] = Open77.time.monotonic()
    print(string.format("[open77_elevators] native %s adopted as Open77 elevator %s",
        tostring(engineEntity), tostring(id)))
end)

RegisterNetEvent("open77:command:result", function(raw, accepted, message)
    if type(raw) ~= "string" or string.match(string.lower(raw), "^elevator%.") == nil then return end
    print(string.format("[server command] %s %s: %s", accepted and "OK" or "ERR", raw, tostring(message)))
end)

exports("get", function(id) return Open77.elevators.get(tonumber(id)) end)
exports("all", Open77.elevators.all)
exports("requestFloor", function(id, floor) return Open77.elevators.request(tonumber(id), floor, "goto") end)
exports("requestCall", function(id, floor) return Open77.elevators.request(tonumber(id), floor, "call") end)

-- Developer probe: `resource.emit open77:elevators:probe`.
AddEventHandler("open77:elevators:probe", function()
    local lifts = Open77.elevators.all()
    print(string.format("[open77_elevators] probe elevators=%d", #lifts))
    for _, lift in ipairs(lifts) do
        print(string.format(
            "[open77_elevators] id=%s entity=%s bucket=%s phase=%s floor=%s target=%s remaining=%s streamed=%s applied=%s revision=%s",
            tostring(lift.id), tostring(lift.engineEntity), tostring(lift.bucket), tostring(lift.phase),
            tostring(lift.activeFloor), tostring(lift.targetFloor), tostring(lift.remainingMs),
            tostring(lift.streamed), tostring(lift.applied), tostring(lift.revision)))
    end
end)

-- Lists native streamed lifts, including unmanaged ones that can be adopted
-- by copying their exact hash and position into a restricted server command.
AddEventHandler("open77:elevators:nearby", function(radius)
    local lifts = Open77.elevators.nearby(tonumber(radius) or 100.0)
    print(string.format("[open77_elevators] nearby native lifts=%d", #lifts))
    for _, lift in ipairs(lifts) do
        print(string.format("[open77_elevators] entity=%s controller=%s pos=%.3f,%.3f,%.3f distance=%.2f floors=%s active=%s managed=%s id=%s",
            lift.engineEntity, lift.controllerEntity, lift.position.x, lift.position.y, lift.position.z, lift.distance,
            tostring(lift.floorCount), tostring(lift.activeFloor), tostring(lift.managed), tostring(lift.id)))
    end
end)

print("network elevator projection ready")
