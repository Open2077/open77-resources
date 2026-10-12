local D=Open77.doors
if type(D)~="table" or type(D.applyNetworkState)~="function" then
    print("[open77_doors] client update required: native door projection unavailable")
    return
end
local states,announced,instances={},{},{}
local epoch,sequence,bucket=nil,0,nil
local lastHello,lastScan=-100,-100
local predictionAvailable=type(D.setNetworkPredictionPolicy)=="function"
    and type(D.resolveNetworkRequest)=="function" and type(D.requestNetworkOpen)=="function"
-- Server-declared door actions (force, pay, hack). A client without this
-- native keeps offering none of them on a locked network door.
local actionsAvailable=type(D.setNetworkActionPolicy)=="function"
-- The server's prediction switch for doors (review item I9, published by the
-- open77_prediction resource in the global state bag). A client with the
-- shared native gate (`Open77.prediction`) applies it -- and the latency
-- ceiling -- at the moment of the interaction itself, leaving an opening in
-- flight alone. An older client only has the per-door policy below, so the
-- switch is folded into it there: flipping it off also withdraws an opening
-- still waiting for its verdict.
local POLICY_KEY="open77.prediction"
local nativeGate=type(Open77.prediction)=="table" and type(Open77.prediction.stats)=="function"
local function doorPredictionSwitch()
    if nativeGate then return true end
    local bag=type(Open77.state)=="table" and Open77.state.global or nil
    if type(bag)~="table" then return true end
    local ok,value=pcall(bag.get,bag,POLICY_KEY)
    return not (ok and type(value)=="table" and type(value.families)=="table" and value.families.door==false)
end
local ACTION_BITS={force=1,pay=2,hack=4}
local function copy(t)
    local out={}
    for k,v in pairs(t) do out[k]=type(v)=="table" and copy(v) or v end
    return out
end
local function actionMask(d)
    local mask=0
    if type(d.actions)=="table" and d.lift==false and d.sealed==false then
        for kind,bit in pairs(ACTION_BITS) do
            if d.actions[kind]~=nil and d.actions[kind]~=false then mask=mask|bit end
        end
    end
    return mask
end
local function clear()
    for id in pairs(states) do
        D.forgetNetworkState(id)
        TriggerEvent("open77:doors:streamedOut",id)
    end
    states,announced,instances={},{},{}
end
local function predictionPolicy(d)
    -- Native revision matching prevents a stale snapshot from granting a
    -- visual lease. Unknown rules, automatic and lift doors never predict.
    D.setNetworkPredictionPolicy(d.id,d.revision,d.lift==false and d.automatic==false
        and d.locked==false and d.sealed==false and d.canOpen==true and doorPredictionSwitch())
end
local function project(d)
    local ok,reason=D.applyNetworkState(d.id,d.revision,d.open,d.locked,d.sealed)
    if predictionAvailable then predictionPolicy(d) end
    -- Same revision contract: a stale snapshot can never advertise an action.
    if actionsAvailable then D.setNetworkActionPolicy(d.id,d.revision,actionMask(d)) end
    return ok,reason
end

D.setNetworkEnabled(true)
-- Older clients only: re-apply the per-door policy when the server switch moves.
if predictionAvailable and not nativeGate and type(Open77.state)=="table"
    and type(Open77.state.onChange)=="function" and Open77.state.global then
    Open77.state.onChange(Open77.state.global,POLICY_KEY,function()
        for _,d in pairs(states) do predictionPolicy(d) end
    end)
end
RegisterNetEvent("open77:doors:sync",function(e,s,kind,payload)
    if type(e)~="number" or type(s)~="number" then return end
    if epoch and e<epoch then return end
    if e==epoch and s<=sequence then return end
    if epoch~=e then clear();epoch=e;sequence=0 end
    sequence=s
    if kind=="reset" then clear();bucket=payload
    elseif kind=="remove" then
        if states[payload] then
            D.forgetNetworkState(payload);states[payload]=nil;instances[payload]=nil
            TriggerEvent("open77:doors:streamedOut",payload)
        end
    elseif kind=="state" and type(payload)=="table" and payload.bucket==bucket then
        local previous=states[payload.id]
        if previous and payload.revision<=previous.revision then return end
        states[payload.id]=payload
        project(payload)
        TriggerEvent(previous and "open77:doors:updated" or "open77:doors:streamedIn",payload.id,copy(payload))
    end
end)

RegisterNetEvent("open77:doors:requestResult",function(id,ok,reason,requestId)
    if not predictionAvailable or not states[id] or type(ok)~="boolean"
        or type(requestId)~="number" or requestId~=requestId or requestId<1
        or requestId>9007199254740991 or requestId%1~=0 then return end
    D.resolveNetworkRequest(id,requestId,ok)
end)

CreateThread(function()
    while true do
        local now=Open77.time.monotonic()
        -- A resource can start before the player has a replicated position.
        if not epoch and now-lastHello>=2 then
            TriggerServerEvent("open77:doors:hello");lastHello=now
        end
        for _,request in ipairs(D.takeNetworkRequests()) do
            local d=states[request.id]
            if request.npc~=nil then
                -- I7: the native AI of a network NPC THIS client simulates asked
                -- this door to open. Forward it for that NPC; the server checks
                -- the authority, the NPC and the door's `npcPassage` rule. Only
                -- a server that advertises the rule is sent one, and never for
                -- an open, lift or sealed door.
                -- B7: a lock and a `never` rule are the server's refusal to
                -- give, by name (npcStats counts `locked`, `npc_passage_denied`).
                -- A walk the navigation found blocked knocks on the door in
                -- front of it (Doors::KnockForNpc) -- a vanilla locked door
                -- never produces the AI's own intent -- and that knock must
                -- reach the server to be admitted or refused, not vanish here.
                if d and request.requestId and type(d.npcPassage)=="string"
                    and not d.lift and not d.sealed and not d.open then
                    TriggerServerEvent("open77:doors:request",request.id,true,request.requestId,"npc",
                        request.npc,request.npcEpoch)
                end
            elseif d and ACTION_BITS[request.action] then
                -- A force/pay/hack intent (the native attaches no prediction to
                -- it). It may target a locked or automatic door; the server
                -- decides. Without a correlation token it is not sent at all.
                if request.requestId and not d.lift then
                    TriggerServerEvent("open77:doors:request",request.id,true,request.requestId,request.action)
                end
            elseif d and not d.lift and not d.automatic then
                if request.requestId then
                    TriggerServerEvent("open77:doors:request",request.id,request.open,request.requestId)
                else
                    TriggerServerEvent("open77:doors:request",request.id,request.open)
                end
            end
        end
        if now-lastScan>=0.5 then
            lastScan=now
            local current,sent={},0
            for _,native in ipairs(D.near(80) or {}) do
                current[native.id]=true
                local d=states[native.id]
                if d then
                    -- Reapply after stream-in, or if a vanilla path changed the
                    -- persistent flags. Native projection is idempotent and
                    -- never restarts an unchanged animation or audio loop.
                    if instances[native.id]~=native.networkInstance or native.open~=d.open
                        or native.locked~=d.locked or native.sealed~=d.sealed then
                        if project(d) then instances[native.id]=native.networkInstance end
                    end
                end
                if native.networkInstance>0 and (not d or (d.lift and d.elevatorId==0))
                    and (not announced[native.id] or now-announced[native.id]>5) and sent<8 then
                    local ok=TriggerServerEvent("open77:doors:discover",{
                        id=native.id,position=native.position,lift=native.lift,doorType=native.doorType,
                        sideOne=native.sideOne,sideTwo=native.sideTwo,automaticClose=native.automaticClose,
                        elevatorId=native.elevatorId,elevatorFloor=native.elevatorFloor,
                    })
                    if ok then announced[native.id]=now;sent=sent+1 end
                end
            end
            for id in pairs(announced) do if not current[id] then announced[id]=nil end end
            for id in pairs(instances) do if not current[id] then instances[id]=nil end end
        end
        -- Drain input on the next client frame. Discovery stays at 2 Hz and
        -- native intent admission remains 5 Hz per door; server rate is unchanged.
        Wait(0)
    end
end)

exports("get",function(id) return states[id] and copy(states[id]) or nil end)
exports("list",function(offset,limit)
    offset,limit=offset or 0,limit or 16
    if type(offset)~="number" or offset<0 or offset>256 or offset%1~=0
        or type(limit)~="number" or limit<1 or limit>16 or limit%1~=0 then return nil,"invalid_page" end
    local out={};for _,d in pairs(states) do out[#out+1]=copy(d) end
    table.sort(out,function(a,b) return a.id<b.id end)
    local page={};for i=offset+1,math.min(#out,offset+limit) do page[#page+1]=out[i] end
    return {doors=page,total=#out,nextOffset=offset+#page<#out and offset+#page or nil}
end)
exports("requestOpen",function(id,open)
    if not states[id] then return false,"unknown_door" end
    if type(open)~="boolean" then return false,"invalid_boolean" end
    local d=states[id]
    if predictionAvailable and d.lift==false and d.automatic==false then
        local queued=D.requestNetworkOpen(id,open)
        if queued then return true end
        -- A known server door may be outside native streaming interest. Keep
        -- the authoritative request available without a visual prediction.
    end
    return TriggerServerEvent("open77:doors:request",id,open)
end)
AddEventHandler("onResourceStop",function(name)
    if name~=GetCurrentResourceName() then return end
    clear();D.setNetworkEnabled(false)
end)
AddEventHandler("open77:doors:probe",function()
    local count=0
    for _,d in pairs(states) do
        count=count+1
        if count<=24 then print(string.format("[open77_doors] %s bucket=%s rev=%s open=%s locked=%s lift=%s/%s",
            d.id,d.bucket,d.revision,tostring(d.open),tostring(d.locked),d.elevatorId,d.elevatorFloor)) end
    end
    print(string.format("[open77_doors] interest=%d epoch=%s sequence=%s",count,tostring(epoch),sequence))
end)
