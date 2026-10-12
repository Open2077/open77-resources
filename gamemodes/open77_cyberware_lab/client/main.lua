-- Optional native feasibility probe. The lab command is open by default.
-- This deliberately exercises the same public APIs available to creators.
local capabilitiesPending = false
local jumpStatePending = false
RegisterNetEvent("open77:cyberlab:jumpstate", function()
    if jumpStatePending then print("[cyberware lab] jump unavailable=request_pending"); return end
    jumpStatePending = true
    CreateThread(function()
        local ok, state, reason = pcall(function()
            if not Open77.exports or type(Open77.exports.call) ~= "function" then return nil, "export_api_unavailable" end
            local pending, why = Open77.exports.call("open77_cyberware", "legsActivity")
            if not pending then return nil, why end
            return pending:await()
        end)
        jumpStatePending = false
        local function scalar(value)
            local kind = type(value)
            if kind ~= "string" and kind ~= "number" and kind ~= "boolean" then return "unknown" end
            return tostring(value):gsub("[%c]", " "):sub(1, 128)
        end
        if not ok or type(state) ~= "table" then
            print("[cyberware lab] jump unavailable=" .. scalar(ok and reason or state)); return
        end
        local fields = {}
        for _, key in ipairs({"sequence","phase","grounded","airborneMs","verticalSpeed"}) do
            fields[#fields+1] = key .. "=" .. scalar(state[key])
        end
        print("[cyberware lab] jump " .. table.concat(fields," "))
    end)
end)
RegisterNetEvent("open77:cyberlab:capabilities", function()
    if capabilitiesPending then print("[cyberware lab] capabilities failed=request_pending"); return end
    capabilitiesPending = true
    CreateThread(function()
        local ok, value, reason = pcall(function()
            if not Open77.exports or type(Open77.exports.call) ~= "function" then return nil, "export_api_unavailable" end
            local promise, why = Open77.exports.call("open77_cyberware", "capabilities")
            if not promise then return nil, why end
            return promise:await()
        end)
        capabilitiesPending = false
        local function scalar(v)
            local kind = type(v)
            if kind ~= "string" and kind ~= "number" and kind ~= "boolean" then return "unknown" end
            return tostring(v):gsub("[%c]", " "):sub(1, 128)
        end
        if not ok or type(value) ~= "table" then
            print("[cyberware lab] capabilities failed=" .. scalar(ok and (reason or "invalid_response") or value))
            return
        end
        local fields = {}
        for _, key in ipairs({"schemaVersion", "side", "profile", "support"}) do fields[#fields+1] = key.."="..scalar(value[key]) end
        for _, group in ipairs({{"compatibility", "protocol", "testedGameBuild", "actualGameBuild", "dlcVerification"},
                {"localProjection", "phase", "reason", "family", "equipmentReadback", "visualProof"},
                {"legsProjection", "phase", "reason", "equipmentReadback", "visualProof"}}) do
            local nested = type(value[group[1]]) == "table" and value[group[1]] or {}
            for i=2,#group do fields[#fields+1] = group[1].."."..group[i].."="..scalar(nested[group[i]]) end
        end
        print("[cyberware lab] capabilities " .. table.concat(fields, " "))
    end)
end)

RegisterNetEvent("open77:cyberlab:fx", function(localEntity, effect, slot, anchor, duration)
    anchor = anchor or "body"
    duration = tonumber(duration) or 8
    if (anchor ~= "body" and anchor ~= "weaponRight") or duration < 5 or duration > 10 then return end
    local handle, reason = Open77.vfx.play(effect, {
        position = { x = 0, y = 0, z = 0 }, duration = duration,
    })
    local createdHandle, attached = handle, false
    if handle then
        attached, reason = Open77.vfx.attach(handle, localEntity, slot, anchor)
        if not attached then Open77.vfx.stop(handle); handle = nil end
    end
    print(("[cyberware lab] native attachment entity=%s effect=%s anchor=%s slot=%s duration=%s created=%s attached=%s handle=%s reason=%s")
        :format(tostring(localEntity), tostring(effect), anchor, tostring(slot), tostring(duration),
            tostring(createdHandle), tostring(attached), tostring(handle), tostring(reason)))
end)

RegisterNetEvent("open77:cyberlab:fxoff", function() Open77.vfx.clear() end)

RegisterNetEvent("open77:cyberlab:fxevent", function(event, anchor)
    anchor = anchor or "body"
    local handle, reason = Open77.vfx.playEntity(event, {
        entity="1", anchor=anchor, duration=8, persistOnDetach=event == "spy_perk_charge",
        breakAllLoops=false,
    })
    print(("[cyberware lab] native entity effect entity=1 event=%s anchor=%s duration=8 handle=%s reason=%s")
        :format(tostring(event), tostring(anchor), tostring(handle), tostring(reason)))
end)

RegisterNetEvent("open77:cyberlab:localprobe", function(enabled)
    if type(enabled) ~= "boolean" then return end
    CreateThread(function()
        local request, reason = Open77.cyberware.projectLocal(enabled)
        if not request then print("[cyberware lab] localprobe refused: " .. tostring(reason)); return end
        for _ = 1, 130 do
            local state
            state, reason = Open77.cyberware.localState(request)
            if state ~= "pending" then
                print(("[cyberware lab] localprobe request=%s enabled=%s state=%s reason=%s"):format(
                    request, tostring(enabled), tostring(state), tostring(reason)))
                return
            end
            Wait(100)
        end
        print("[cyberware lab] localprobe timed out")
    end)
end)

-- Receiver-local, same-family appearance feasibility through the public native
-- projector. A server installation uses the PATIENT'S captured variant instead.
RegisterNetEvent("open77:cyberlab:armsprobe", function(player, enabled)
    local body, reason = false, nil
    if enabled then body, reason = Open77.cyberware.captureArms() end
    local ok = false
    if body ~= nil then ok, reason = Open77.cyberware.presentArms(player, body) end
    print(("[cyberware lab] armsprobe target=%s accepted=%s reason=%s"):format(
        tostring(player), tostring(ok), tostring(reason)))
end)
RegisterNetEvent("open77:cyberlab:profile", function()
    local profile, reason = Open77.cyberware.captureArms()
    if not profile then print("[cyberware lab] native profile failed=" .. tostring(reason)); return end
    for _, group in ipairs(profile.groups) do
        print("[cyberware lab] native profile family=" .. profile.family .. " group=" .. group.name)
        for _, pair in ipairs(group.keys) do print("[cyberware lab] native key=" .. pair[1] .. ":" .. pair[2]) end
    end
end)

RegisterNetEvent("open77:cyberlab:action", function()
    local state, reason = Open77.cyberware.attackState()
    if not state then print("[cyberware lab] native action failed=" .. tostring(reason)); return end
    print(("[cyberware lab] native action sequence=%s holding=%s variant=%s record=%s")
        :format(state.sequence, tostring(state.holding), state.variant, state.record))
    local fields = {}
    for key, value in pairs(state) do
        if type(value) == "string" or type(value) == "number" or type(value) == "boolean" then
            fields[#fields + 1] = tostring(key) .. "=" .. tostring(value)
        end
    end
    table.sort(fields)
    print("[cyberware lab] native action state=" .. table.concat(fields, " "))
end)

-- Read in the support owner's VM; a native call here cannot observe its lease.
local slamActivityPending=false
RegisterNetEvent("open77:cyberlab:slamActivity",function()
    if slamActivityPending then print("[cyberware lab] slam unavailable=request_pending");return end
    slamActivityPending=true
    CreateThread(function()
        local ok,value,reason=pcall(function()
            if not Open77.exports or type(Open77.exports.call)~="function" then return nil,"export_api_unavailable" end
            local promise,why=Open77.exports.call("open77_cyberware","slamActivity")
            if not promise then return nil,why end
            return promise:await()
        end)
        local presentationOk,presentation,presentationReason=pcall(function()
            if not Open77.exports or type(Open77.exports.call)~="function" then return nil,"export_api_unavailable" end
            local promise,why=Open77.exports.call("open77_cyberware","slamPresentation")
            if not promise then return nil,why end
            return promise:await()
        end)
        slamActivityPending=false
        local function scalar(v)
            if type(v)=="number" then return v==v and math.abs(v)<math.huge and v or "unknown" end
            if type(v)=="boolean" then return v end
            if type(v)=="string" then return v:gsub("[%c]"," "):sub(1,128) end
            return "unknown"
        end
        local activityAvailable=ok and type(value)=="table"
        local result={activityAvailable=activityAvailable}
        if not activityAvailable then
            result.activityError=scalar(ok and reason or value)
            value={}
        end
        for _,key in ipairs({"sequence","phase","mode","reason","lastServerError","phaseSequence","impactSequence",
            "elapsedMs","grounded","verticalSpeed"}) do result[key]=scalar(value[key]) end
        for _,key in ipairs({"position","contact"}) do
            local v=value[key]
            if type(v)=="table" then result[key]={x=scalar(v.x),y=scalar(v.y),z=scalar(v.z)} end
        end
        result.presentation={}
        if presentationOk and type(presentation)=="table" then
            for _,key in ipairs({"reason","player","activation","phaseSequence","effect"}) do
                result.presentation[key]=scalar(presentation[key])
            end
        else
            result.presentation.reason=scalar(presentationOk and presentationReason or presentation)
        end
        local encoded,encodeReason=Open77.json.encode(result)
        if not encoded then
            print("[cyberware lab] slam unavailable="..tostring(scalar(encodeReason)));return
        end
        print("[cyberware lab] slam "..encoded)
    end)
end)

-- Catalog-only world probe: no attachment, damage, or arbitrary depot paths.
local worldProbeUntil=0
RegisterNetEvent("open77:cyberlab:fxworld",function(effect,at)
    local function refuse(reason) print("[cyberware lab] fxworld refused="..reason) end
    if effect~="impact.ground_slam" and effect~="explosion.frag" then refuse("effect_not_approved");return end
    local function finite(v) return type(v)=="number" and v==v and math.abs(v)<=1000000 end
    if type(at)~="table" or not finite(at.x) or not finite(at.y) or not finite(at.z) then refuse("finite_xyz_required");return end
    local body=Open77.character.state()
    local p=body and body.position
    if not p or not finite(p.x) or not finite(p.y) or not finite(p.z) then refuse("body_unavailable");return end
    if (p.x-at.x)^2+(p.y-at.y)^2+(p.z-at.z)^2>100 then refuse("distance_exceeds_10m");return end
    local t=Open77.time.monotonic()
    if t<worldProbeUntil then refuse("probe_busy");return end
    local handle,reason=Open77.vfx.play(effect,{position={x=at.x,y=at.y,z=at.z},duration=3})
    if not handle then refuse(tostring(reason):gsub("[%c]"," "):sub(1,128));return end
    worldProbeUntil=t+3
    print("[cyberware lab] fxworld native_spawn_accepted effect="..effect.." duration=3")
end)
