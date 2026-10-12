-- open77_forcedoor — client side
--
-- Receives the force-door event from the server and uses the Open77.doors
-- API to:
--   1. Find the door the player is looking at (Open77.doors.aimedAny() — the
--      controller-agnostic resolve that also returns static/scenery doors)
--   2. Unlock it (Open77.doors.unlock)
--   3. Open it (Open77.doors.open)
--   4. If despawn mode, sink it below the floor via Open77.doors.sink — the
--      native root-transform write that moves even controller-less doors
--      (parity with RedSync's SinkObject / AMM force-open).
--
-- This is the Open77 equivalent of RedSync's RedSyncWorldTools.ForceOpenLookedDoor()

local function forceDoor(despawn)
    -- Get the door the player is aiming at. Prefer the controller-agnostic
    -- resolve (lands static/scenery doors too); fall back to the classic
    -- aimed() if the client kernel predates aimedAny.
    local door, reason
    if Open77.doors.aimedAny then
        door, reason = Open77.doors.aimedAny()
    else
        door, reason = Open77.doors.aimed()
    end
    if not door then
        print("[open77_forcedoor] " .. tostring(reason or "no door targeted"))
        return
    end

    local id = door.id
    local className = tostring(door.class or "Door")
    local doorName = tostring(door.name or "")

    -- Unlock the door first (clears lock/seal state)
    local unlockOk, unlockReason = Open77.doors.unlock(id)
    if not unlockOk then
        print("[open77_forcedoor] unlock failed: " .. tostring(unlockReason))
    end

    -- Open the door (controller-backed doors respond; static doors won't)
    local openOk, openReason = Open77.doors.open(id)
    if openOk then
        local msg = string.format("[open77_forcedoor] Forced open '%s' (%s)",
            doorName ~= "" and doorName or className, tostring(id))
        print(msg)
    else
        -- If open failed, try reset then open again
        Open77.doors.reset(id)
        Wait(50)
        Open77.doors.unlock(id)
        openOk, openReason = Open77.doors.open(id)
        if openOk then
            print(string.format("[open77_forcedoor] Forced open '%s' (retry)", className))
        else
            print("[open77_forcedoor] open failed: " .. tostring(openReason))
        end
    end

    -- Despawn mode: sink static/scenery doors below the floor via the native
    -- root-transform write (RedSync SinkObject parity). Works even when the
    -- door has no controller PS and ignores open/unlock.
    if despawn and not openOk then
        if Open77.doors.sink then
            local sinkOk, sinkReason = Open77.doors.sink(id, 3.0)
            if sinkOk then
                print(string.format("[open77_forcedoor] Sunk static door '%s' (%s)", className, tostring(id)))
            else
                print("[open77_forcedoor] sink failed: " .. tostring(sinkReason))
            end
        else
            print("[open77_forcedoor] Door resisted open+unlock, and this client has no sink native yet.")
        end
    end
end

RegisterNetEvent("open77_forcedoor:execute", function(despawn)
    forceDoor(despawn)
end)

AddEventHandler("onClientResourceStart", function(name)
    if name ~= GetCurrentResourceName() then return end
    print("[open77_forcedoor] client ready -- aim at a door and type /forcedoor")
end)
