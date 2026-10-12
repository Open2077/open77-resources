-- Replaceable open-access lab policy. Grants are session abilities, not implants.
-- Edit this binding/configuration before starting the resource to suit a server.
CyberwareLabSlam = {}
-- L is unused by normal gameplay in the audited installed mappings. G overlaps
-- native ToggleWalk/vehicle actions; creators should audit their own bindings.
local inputKey = "l"
local presets = {
    {id="harmless",label="Harmless",description="Native slam with no damage or knockback.",damage=0,knockback=0},
    {id="combat",label="Combat",description="Nonlethal area damage and knockback, subject to combat rules.",damage=35,knockback=1.5},
    {id="gorilla",label="Gorilla",description="Combat preset requiring active Gorilla Arms.",damage=35,knockback=1.5,arms=true},
    {id="parkour",label="Parkour",description="Combat preset requiring active double-jump legs.",damage=35,knockback=1.5,legs=true},
}
local definitions, failures, reads, actions = {}, {}, {}, {}
local outcomeHistory = {}
local function compact(value)
    if type(value)~="table" then return nil end
    local result={}
    for key,v in pairs(value) do
        if type(key)=="string" and #key<=64 then
            if type(v)=="boolean" or (type(v)=="number" and v==v and math.abs(v)<math.huge) then result[key]=v
            elseif type(v)=="string" then
                v=v:gsub("[%c]"," ")
                if #v>128 then v=v:sub(1,(utf8.offset(v,0,129) or 129)-1) end
                result[key]=v
            end
        end
    end
    return result
end
local function compactEvent(value)
    local result=compact(value)
    local p=type(value.position)=="table" and value.position
    if p and type(p.x)=="number" and type(p.y)=="number" and type(p.z)=="number"
        and p.x==p.x and p.y==p.y and p.z==p.z and math.abs(p.x)<math.huge
        and math.abs(p.y)<math.huge and math.abs(p.z)<math.huge then
        result.position={x=p.x,y=p.y,z=p.z}
    end
    if type(value.targets)=="table" then
        result.targets={}
        for i=1,math.min(8,#value.targets) do
            local target=value.targets[i]
            if type(target)=="table" then
                result.targets[#result.targets+1]=compact({player=target.player,accepted=target.accepted,
                    amount=target.amount,error=target.error,motionError=target.motionError})
            end
        end
        result.targetsOmitted=math.max(0,#value.targets-8)
    end
    return result
end
local function compactStats(value)
    local result=compact(value)
    if not result then return nil end
    for _,pool in ipairs({"health","stamina"}) do
        local current=type(value[pool])=="table" and value[pool].value
        if type(current)=="number" and current==current and math.abs(current)<math.huge then result[pool]=current end
    end
    return result
end
local function id(value)
    local n=tonumber(value)
    return n and n>0 and n<=9007199254740991 and n%1==0 and n or nil
end
local function connected(value)
    local n=id(value);return n and Open77.players.name(n) and n or nil
end
-- These are server-local authority notifications, never client hit claims.
-- Keep a small diagnostic ring; print only when explicitly queried.
for _,eventName in ipairs({"onAbilityActivation","onAbilityPhase","onAbilityCancelled","onAbilityImpact","onAbilityMotionOutcome"}) do
    AddEventHandler(eventName,function(player,encoded)
        local target=id(player)
        if not target or type(encoded)~="string" then return end
        local ok,event=pcall(json.decode,encoded)
        if not ok or type(event)~="table" or event.player~=target then return end
        local history=outcomeHistory[target] or {}
        if #history>=16 then table.remove(history,1) end
        history[#history+1]={notification=eventName,receivedAt=GetGameTimer(),event=compactEvent(event)}
        outcomeHistory[target]=history
    end)
end
local function snapshot(target)
    local grant,reason=Open77.abilities.current(target)
    local catalog={}
    for _,preset in ipairs(presets) do
        catalog[#catalog+1]={id=preset.id,label=preset.label,description=preset.description,
            available=definitions[preset.id]~=nil,error=failures[preset.id],
            damage=preset.damage,knockback=preset.knockback}
    end
    return {target=target,grant=grant,presets=catalog,inputKey=inputKey,reason=reason}
end
local function send(issuer,suffix,value)
    if connected(issuer) then TriggerClientEvent("open77:cyberlab:slam:"..suffix,issuer,value) end
end
CreateThread(function()
    for _,preset in ipairs(presets) do
        local definition={id="cyberlab.ground_slam."..preset.id,version=1,profile="ground_slam",config={
            inputKey=inputKey,allowGround=true,allowAir=true,requiredArms=preset.arms==true,requiredLegs=preset.legs==true,
            cosmetic=preset.damage==0,nonlethal=true,damage=preset.damage,knockbackMeters=preset.knockback,
            staminaCost=20,cooldownMs=5000,radius=4,innerRadius=1,edgeMultiplier=0.25,
            heightBonusPerMeter=0,maxHeight=10,maxActivationMs=5000,geometryDeadlineMs=750,maxFloorDelta=0.75,
            -- Native GroundSlamNear concrete material uses this same effect.
            -- Its original attack is suppressed because authority owns damage.
            impactEffect="impact.ground_slam",effectOnOwner=true,
            -- Authored on both native slam clips; owner already hears that track.
            impactSound="w_cyb_strongarms_hit_back",soundOnOwner=false}}
        local result,reason=Open77.abilities.define(definition)
        if result and result.ok then definitions[preset.id]=definition.id else failures[preset.id]=reason or "definition_unavailable" end
        print("[cyberware lab] slam preset="..preset.id.." result="..tostring(reason or (result and result.ok)))
    end
end)
local function operate(issuer,target,action,preset)
    if not connected(target) then return false,"player_unavailable" end
    if action=="state" then return true,snapshot(target) end
    local result,reason
    if action=="grant" then
        local definition=definitions[preset or "harmless"]
        if not definition then return false,failures[preset] or "unknown_preset" end
        result,reason=Open77.abilities.grant(target,definition)
    elseif action=="revoke" then result,reason=Open77.abilities.revoke(target)
    elseif action=="cancel" then result,reason=Open77.abilities.cancel(target)
    else return false,"invalid_action" end
    return result~=nil and result.ok==true,reason or (result and result.error)
end
-- Main command integration: cyberlab slam <grant|revoke|cancel|state> [player] [preset].
-- An omitted player selects the issuing client; console must specify a player.
function CyberwareLabSlam.command(issuer,args)
    local action=args[1] or "state"
    local target=args[2]~=nil and id(args[2]) or id(issuer)
    if not target then return false,"positive_player_required" end
    if action=="diagnostics" then
        if not connected(target) then return false,"player_unavailable" end
        local grant=Open77.abilities.current(target)
        local report={target=target,grant=compact(grant),config=compact(grant and grant.definition and grant.definition.config),
            stats=compactStats(Open77.stats.get(target)),life=compact(Open77.players.getLifeState(target)),outcomes={},
            admissionReasonSource="Owner slamActivity export lastServerError"}
        for _,entry in ipairs(outcomeHistory[target] or {}) do report.outcomes[#report.outcomes+1]=entry end
        local encoded,reason=json.encode(report)
        while encoded and #encoded>8192 and #report.outcomes>0 do
            table.remove(report.outcomes,1);report.omittedOldest=true;encoded,reason=json.encode(report)
        end
        if not encoded then return false,reason or "diagnostics_encode_failed" end
        if #encoded>8192 then
            report={target=target,error="diagnostics_size_limit",outcomes={}}
            encoded,reason=json.encode(report)
        end
        if not encoded or #encoded>8192 then return false,"diagnostics_size_limit" end
        print("[cyberware lab] slam diagnostics "..encoded)
        return true,("diagnostics player=%s outcomes=%s bytes=%s; bounded report in server log; native state via slam activity")
            :format(target,#report.outcomes,#encoded)
    end
    if action=="activity" then
        if not connected(target) then return false,"player_unavailable" end
        local ok,reason=TriggerClientEvent("open77:cyberlab:slamActivity",target)
        return ok~=false,reason or "activity_requested"
    end
    local ok,result=operate(issuer,target,action,args[3])
    if connected(issuer) then send(issuer,"data",snapshot(target)) end
    if ok and action=="state" then return true,json.encode(result) end
    return ok,result
end
RegisterNetEvent("open77:cyberlab:slam:request",function(payload)
    local issuer=connected(source)
    if not issuer or type(payload)~="table" then return end
    local target=payload.target==nil and issuer or connected(payload.target)
    if not target then return end
    local t=GetGameTimer();if reads[issuer] and t-reads[issuer]<100 then return end;reads[issuer]=t
    send(issuer,"data",snapshot(target))
end)
RegisterNetEvent("open77:cyberlab:slam:action",function(payload)
    local issuer=connected(source)
    if not issuer or type(payload)~="table" then return end
    local target=payload.target==nil and issuer or id(payload.target)
    local t=GetGameTimer();if actions[issuer] and t-actions[issuer]<200 then return end;actions[issuer]=t
    local ok,reason=operate(issuer,target,payload.action,payload.preset)
    send(issuer,"result",{target=target,ok=ok,message=not ok and tostring(reason) or
        (payload.action=="grant" and "Grant requested. Close the panel and use the ability key when ready."
        or payload.action=="revoke" and "Ground Slam revoked." or "Cancellation requested.")})
    if connected(target) then send(issuer,"data",snapshot(target)) end
end)
AddEventHandler("onPlayerDisconnected",function(player) player=id(player);if player then reads[player]=nil;actions[player]=nil;outcomeHistory[player]=nil end end)
