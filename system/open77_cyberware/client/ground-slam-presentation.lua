-- Native VFX service driven exclusively by authenticated server phase events.
-- The owner may already have native Quake presentation; echo is explicit.
local seen, playing = {}, {}
local presentations,currentByPlayer,bodyEpochs={},{},{}
local stopped=false
-- One bounded diagnostic receipt; a successful native handle is not visual proof.
local diagnostic={reason="no_impact_received"}
local function note(reason,value)
    local function scalar(v) if type(v)=="number" then return v elseif type(v)=="string" then return v:sub(1,128) end end
    diagnostic={reason=reason,player=scalar(value and value.player),activation=scalar(value and value.activation),
        phaseSequence=scalar(value and value.phaseSequence),
        effect=scalar(value and type(value.config)=="table" and value.config.impactEffect)}
end
exports("slamPresentation",function()
    local result={};for k,v in pairs(diagnostic) do result[k]=v end;return result
end)
local function token(v) return type(v)=="string" and #v==32 and v:match("^%x+$") end
local function finite(v) return type(v)=="number" and v==v and math.abs(v)<math.huge end
local function countSeen(t)
    local count=0
    for id,expiry in pairs(seen) do if t>=expiry then seen[id]=nil else count=count+1 end end
    return count
end
local function now() return Open77.time.monotonic() end
local function stop(id)
    local item=playing[id]
    if item then
        for _,handle in ipairs(item.handles) do Open77.vfx.stop(handle) end
        playing[id]=nil
    end
end
-- The authored native Quake resource (charged_jump.effect) is one short burst of
-- twelve dust particles and a small refraction ring: measured captures showed a
-- single instance reads as a footstep from third-person distance. The impact
-- therefore lays the same audited alias out as a centre puff plus a ring of
-- three, the ring sized from the definition's own bounded damage radius. Four
-- instances per impact stay inside the 32-effect cap; no new identifier is used.
local BURST_RING={{0.0,0.0},{1.0,0.0},{-0.5,0.8660254},{-0.5,-0.8660254}}
local function burstRadius(config)
    local radius=type(config.radius)=="number" and config.radius==config.radius and config.radius or 4
    return math.max(0.5,math.min(1.5,radius*0.25))
end
local function burst(effect,at,config)
    local handles={}
    local ring=burstRadius(config)
    for index,offset in ipairs(BURST_RING) do
        local scale=index==1 and 0 or ring
        local handle,reason=Open77.vfx.play(effect,{position={x=at.x+offset[1]*scale,y=at.y+offset[2]*scale,z=at.z},duration=3})
        if not handle then
            for _,started in ipairs(handles) do Open77.vfx.stop(started) end
            return nil,reason
        end
        handles[#handles+1]=handle
    end
    return handles
end
local function context()
    local session=Open77.network.status()
    if not session or session.phase~="active" then return nil end
    local life=Open77.players.getLifeState(session.playerId)
    return session,life
end
local function impact(value)
    if stopped or type(value)~="table" or value.phase~="impact" or not token(value.activation)
        or not token(value.incarnation) or type(value.player)~="number" or value.player<=0 or value.player%1~=0
        or type(value.config)~="table" or type(value.position)~="table" then return end
    local session,life=context()
    if not session or not life or life.bucket~=value.bucket then note("local_context",value);return end
    if seen[value.activation] then return end
    local sourceLife=Open77.players.getLifeState(value.player)
    if not sourceLife or sourceLife.bucket~=value.bucket or sourceLife.phase~="alive" then note("source_context",value);return end
    if countSeen(now())>=512 then note("receipt_cap",value);return end
    seen[value.activation]=now()+60
    local effect=value.config.impactEffect
    if type(effect)~="string" or effect=="" or
        (session.playerId==value.player and value.config.effectOnOwner~=true) then note("effect_disabled_or_owner_excluded",value);return end
    local body=Open77.character.state()
    local p=body and body.position
    local at=value.position
    if not p or not finite(at.x) or not finite(at.y) or not finite(at.z) then note("invalid_position",value);return end
    local distance=(p.x-at.x)^2+(p.y-at.y)^2+(p.z-at.z)^2
    if distance~=distance or distance>90*90 then note("out_of_range",value);return end
    local count=0;for _,item in pairs(playing) do count=count+#item.handles end
    if count+#BURST_RING>32 then note("effect_cap",value);return end
    local handles,reason=burst(effect,at,value.config)
    if handles then note("native_spawn_accepted",value);playing[value.activation]={handles=handles,bucket=value.bucket,untilAt=now()+3,player=value.player,revision=sourceLife.revision}
    else note("native_spawn_refused:"..tostring(reason):sub(1,128),value);Open77.log.warn("slam impact VFX refused: "..tostring(reason)) end
end
local phases={windup=true,descent=true,contact=true,impact=true,recovery=true,complete=true,cancelled=true,rejected=true}
local terminal={complete=true,cancelled=true,rejected=true}
local function present(item)
    if type(Open77.abilities)~="table" or type(Open77.abilities.presentSlam)~="function" then return false end
    return Open77.abilities.presentSlam(item.player,item.activation,item.sequence,item.phase,item.air,
        math.min(30000,item.elapsed+math.floor((now()-item.received)*1000)))==true
end
local function retire(item)
    if not item or item.closed then return end
    if item.sequence<4294967295 and type(Open77.abilities)=="table" and type(Open77.abilities.presentSlam)=="function" then
        Open77.abilities.presentSlam(item.player,item.activation,item.sequence+1,"cancelled",item.air,item.elapsed)
    end
    item.closed=true;item.retryUntil=nil
    if currentByPlayer[item.player]==item.activation then currentByPlayer[item.player]=nil end
end
local function animation(value)
    if stopped or type(value)~="table" or not phases[value.phase] or not token(value.activation)
        or not token(value.incarnation) or type(value.player)~="number" or value.player<=0 or value.player%1~=0
        or not finite(value.phaseSequence) or value.phaseSequence<=0 or value.phaseSequence%1~=0
        or value.phaseSequence>4294967295 or not finite(value.elapsedMs) or value.elapsedMs<0
        or value.elapsedMs>30000 or value.elapsedMs%1~=0 or not finite(value.serverTime)
        or (value.mode~="air" and value.mode~="ground") then return end
    local session,life=context()
    local sourceLife=Open77.players.getLifeState(value.player)
    if not session or not life or life.bucket~=value.bucket or not sourceLife
        or sourceLife.bucket~=value.bucket or sourceLife.phase~="alive" then return end
    local epoch=bodyEpochs[value.player]
    if epoch and (value.serverTime<epoch.serverTime or
        (epoch.incarnation~=value.incarnation and value.serverTime==epoch.serverTime)) then return end
    local item=presentations[value.activation]
    if item and (item.closed or item.incarnation~=value.incarnation or item.player~=value.player
        or item.revision~=sourceLife.revision or value.phaseSequence<=item.sequence) then return end
    local old=presentations[currentByPlayer[value.player]]
    if old and old.activation~=value.activation then
        if old.serverTime>value.serverTime then return end
        retire(old)
    end
    if not item then
        local count=0;for _ in pairs(presentations) do count=count+1 end
        if count>=512 then return end
        item={activation=value.activation,player=value.player,incarnation=value.incarnation,revision=sourceLife.revision}
        presentations[value.activation]=item
    end
    local epochCount=0;for _ in pairs(bodyEpochs) do epochCount=epochCount+1 end
    if not epoch and epochCount>=512 then return end
    bodyEpochs[value.player]={incarnation=value.incarnation,serverTime=value.serverTime,expiry=now()+60}
    item.sequence=value.phaseSequence;item.phase=value.phase;item.air=value.mode=="air"
    item.elapsed=0;item.received=now();item.serverTime=value.serverTime -- Present uses age within this phase, not activation elapsed.
    item.bucket=value.bucket;item.expiry=now()+60;item.retryUntil=now()+0.25
    currentByPlayer[item.player]=item.activation
    if present(item) then item.retryUntil=nil end
    if terminal[item.phase] then item.closed=true;item.retryUntil=nil;currentByPlayer[item.player]=nil end
    return true
end
RegisterNetEvent("open77:abilities:phase",function(value)
    if animation(value) then impact(value)
    elseif type(value)=="table" and value.phase=="impact" then note("animation_gate_or_duplicate",value) end
end)
RegisterNetEvent("open77:abilities:cancel",function(value)
    if stopped or type(value)~="table" or not token(value.activation) then return end
    if seen[value.activation] or countSeen(now())<512 then seen[value.activation]=now()+60 end
    stop(value.activation)
    local item=presentations[value.activation]
    if item then retire(item) else
        local count=0;for _ in pairs(presentations) do count=count+1 end
        if count<512 then presentations[value.activation]={closed=true,expiry=now()+60} end
    end
end)
CreateThread(function()
    while not stopped do
        Wait(100)
        local session,life=context()
        local t=now()
        for id,item in pairs(playing) do
            local sourceLife=Open77.players.getLifeState(item.player)
            if not session or not life or life.bucket~=item.bucket or t>=item.untilAt
                or not sourceLife or sourceLife.bucket~=item.bucket or sourceLife.phase~="alive"
                or sourceLife.revision~=item.revision then stop(id) end
        end
        for id,item in pairs(presentations) do
            local sourceLife=Open77.players.getLifeState(item.player)
            if t>=item.expiry then retire(item);presentations[id]=nil
            elseif not item.closed then
                if not session or not life or life.bucket~=item.bucket or not sourceLife
                    or sourceLife.bucket~=item.bucket or sourceLife.phase~="alive"
                    or sourceLife.revision~=item.revision then retire(item)
                elseif item.retryUntil then
                    if t>=item.retryUntil then item.retryUntil=nil
                    elseif present(item) then item.retryUntil=nil end
                end
            end
        end
        for player,epoch in pairs(bodyEpochs) do if t>=epoch.expiry then bodyEpochs[player]=nil end end
        for id,expiry in pairs(seen) do if t>=expiry then seen[id]=nil end end
    end
end)
local function shutdown(name)
    if name~=GetCurrentResourceName() then return end
    stopped=true
    for id in pairs(playing) do stop(id) end
    for _,item in pairs(presentations) do retire(item) end
    seen={};presentations={};currentByPlayer={};bodyEpochs={}
end
AddEventHandler("onClientResourceStop",shutdown)
AddEventHandler("onResourceStop",shutdown)
