-- Local presentation only. A gamemode must publish its known combat policy;
-- missing policy fails closed. No candidate or prediction is sent to the server.
CyberwarePrediction = {}
local policy, protection, contacts = nil, {}, {}
local refused = {}
local slamContact
local protectionOverflowUntil=0
local function now() return Open77.time.monotonic() * 1000 end
local function finite(n) return type(n)=="number" and n==n and math.abs(n)<math.huge end
local function point(p) return type(p)=="table" and finite(p.x) and finite(p.y) and finite(p.z) end
local function playerPosition(player)
    local entity=Open77.players.entity(player)
    if entity==nil then return end
    local x,y,z=Open77.character.position(entity)
    if finite(x) and finite(y) and finite(z) then return {x=x,y=y,z=z} end
end
local function deny(reason)
    refused[reason]=(refused[reason] or 0)+1
    return nil,reason
end
-- The server's operator policy (review items I6/I9): per-family switches and
-- a round-trip ceiling above which no NEW prediction starts; one in flight
-- finishes normally. Published by the open77_prediction resource in the global
-- state bag and read at the point of use, so a flip applies to the very next
-- prediction. Without it every family is on and the ceiling is 250 ms, the
-- client's compiled default (network/PredictionPolicy.hpp) -- a server that
-- never loads open77_prediction still gets the latency gate.
local POLICY_KEY,DEFAULT_MAX_PING_MS,MAX_PING_CEILING_MS="open77.prediction",250,5000
local skipped={}
local function serverPolicy()
    local state=Open77.state
    local bag=type(state)=="table" and state.global or nil
    if type(bag)~="table" then return nil end
    local ok,value=pcall(bag.get,bag,POLICY_KEY)
    return ok and type(value)=="table" and value or nil
end
local function gate(kind,session)
    local value=serverPolicy()
    if value and type(value.families)=="table" and value.families[kind]==false then return "prediction_disabled" end
    local ceiling=value and tonumber(value.maxPingMs)
    if not finite(ceiling) or ceiling<0 or ceiling>MAX_PING_CEILING_MS then ceiling=DEFAULT_MAX_PING_MS end
    -- An unknown round trip (<= 0: not sampled yet) is not a reason to refuse.
    local ping=session and tonumber(session.ping)
    if ceiling>0 and finite(ping) and ping>ceiling then return "prediction_latency" end
end
local function skip(kind,reason)
    local counts=skipped[kind] or {disabled=0,latency=0}
    skipped[kind]=counts
    if reason=="prediction_latency" then counts.latency=counts.latency+1 else counts.disabled=counts.disabled+1 end
    return deny(reason)
end
function CyberwarePrediction.cancel(kind,action,victim)
    for _,v in pairs(contacts) do
        if (not kind or v.kind==kind) and (not action or v.action==tostring(action)) and (not victim or v.victim==victim) then
            if v.handle then
                if type(Open77.motion.refutePrediction)=="function" then Open77.motion.refutePrediction(v.handle) end
                v.handle=nil
            end
        end
    end
end
-- An authority verdict for ONE victim of ONE action. It can precede the local
-- prediction (a Ground Slam target's geometry is refused before the local
-- impact), so it is also remembered briefly and the late prediction is never
-- made. Keyed by the exact kind/action/victim: another action is untouched,
-- and an adopted prediction is a native no-op.
local refutations={}
local function refutationKey(kind,action,victim)
    return tostring(kind)..":"..tostring(action)..":"..tostring(math.tointeger(victim) or victim)
end
function CyberwarePrediction.refute(kind,action,victim)
    if not kind or action==nil or not finite(victim) or victim<=0 or victim%1~=0 then return end
    local stamp,count=now(),0
    for key,expiry in pairs(refutations) do
        if stamp>=expiry then refutations[key]=nil else count=count+1 end
    end
    if count<64 then refutations[refutationKey(kind,action,victim)]=stamp+3000 end
    CyberwarePrediction.cancel(kind,action,victim)
end
-- The terminal verdict of one action: a prediction whose victim is not kept
-- (no authoritative reaction started) will not happen.
function CyberwarePrediction.refuteExcept(kind,action,keep)
    if not kind or action==nil or type(keep)~="table" then return end
    for _,v in pairs(contacts) do
        if v.kind==kind and v.action==tostring(action) and not keep[v.victim] and v.handle then
            if type(Open77.motion.refutePrediction)=="function" then Open77.motion.refutePrediction(v.handle) end
            v.handle=nil
        end
    end
end
function CyberwarePrediction.clear()
    CyberwarePrediction.cancel()
    protection,contacts,refutations={},{},{};protectionOverflowUntil=0;slamContact=nil
end
AddEventHandler("open77_prediction:cancel",function(kind,action,victim) CyberwarePrediction.cancel(kind,action,victim) end)
AddEventHandler("open77_prediction:policy",function(value)
    policy=type(value)=="table" and value or nil
end)
AddEventHandler("onClientResourceStop",function(name)
    if policy and name==policy.owner then policy=nil end
end)
AddEventHandler("onClientResourceStart",function(name)
    if name==GetCurrentResourceName() then TriggerEvent("open77_prediction:requestPolicy") end
end)
-- Called only after the authenticated motion envelope/sequence checks. The
-- native get-up tail is shorter than the server's busy + CC protection window.
function CyberwarePrediction.observeMotion(value,offset)
    local count,stamp=0,now()
    for id,v in pairs(protection) do
        if stamp>=v.untilAt then protection[id]=nil else count=count+1 end
    end
    if count>=256 and not protection[value.player] then protectionOverflowUntil=stamp+7500;return end
    local life=Open77.players.getLifeState(value.player)
    if not life or life.phase~="alive" or life.bucket~=value.bucket then return end
    if value.lifeRevision and value.lifeRevision>0 and value.lifeRevision~=life.revision then return end
    if value.phase=="ended" then CyberwarePrediction.cancel(nil,nil,value.player) end
    local previous=protection[value.player]
    local untilAt
    if value.phase=="active" and finite(value.expiresAt) and finite(offset) then
        untilAt=math.min(now()+7500,value.expiresAt+offset+1500)
    elseif value.phase=="ended" and previous and previous.incarnation==value.incarnation then
        untilAt=now()+1500
    end
    if not untilAt then return end
    protection[value.player]={revision=life.revision,bucket=life.bucket,incarnation=value.incarnation,untilAt=untilAt}
end
local function safeZone(p)
    local radius=policy.safeZoneRadius or 0
    if not finite(radius) then return true end
    for _,center in ipairs(policy.safeZones or {}) do
        if not point(center) then return true end
        local x,y,z=p.x-center.x,p.y-center.y,p.z-center.z
        if radius>0 and x*x+y*y+z*z<=radius*radius then return true end
    end
    return false
end
function CyberwarePrediction.request(kind,victim,action,x,y,damage)
    if type(Open77.motion.refutePrediction)~="function" then return deny("prediction_backend_unavailable") end
    if kind~="melee" and kind~="slam" and kind~="hack" then return deny("source") end
    if not finite(victim) or victim<=0 or victim%1~=0 or not finite(damage) or damage<0
        or not finite(x) or not finite(y) or x*x+y*y<0.000001 then return deny("candidate") end
    local refutedUntil=refutations[refutationKey(kind,action,victim)]
    if refutedUntil and now()<refutedUntil then return deny("refuted") end
    if not policy or policy.enabled~=true then return deny("policy_unavailable") end
    local session=Open77.network.status()
    local attacker=session and tonumber(session.playerId)
    if not attacker or session.phase~="active" or attacker==victim then return deny("session") end
    local mine,theirs=Open77.players.getLifeState(attacker),Open77.players.getLifeState(victim)
    if not mine or not theirs or mine.phase~="alive" or theirs.phase~="alive" then return deny("life") end
    -- The supplied policy explicitly covers a bucket. Arena teams, loadout
    -- verification and spawn shields need their own policy before opting in.
    if mine.bucket~=policy.bucket or theirs.bucket~=policy.bucket then return deny("policy_bucket") end
    local a,b=playerPosition(attacker),playerPosition(victim)
    if not point(a) or not point(b) then return deny("position") end
    if safeZone(a) or safeZone(b) then return deny("safe_zone") end
    local stamp=now()
    if stamp<protectionOverflowUntil then return deny("protection_capacity") end
    for id,v in pairs(protection) do if stamp>=v.untilAt then protection[id]=nil end end
    local cc=protection[victim]
    if cc and cc.revision==theirs.revision and cc.bucket==theirs.bucket then return deny("cc_protected") end
    local key=kind..":"..tostring(action)..":"..victim..":"..theirs.revision
    local count=0
    for id,value in pairs(contacts) do
        if stamp>=value.expiry then contacts[id]=nil else count=count+1 end
    end
    if contacts[key] then return deny("duplicate") end
    if count>=128 then return deny("capacity") end
    local multiplier=(policy.damageMultiplier or 1)*(kind=="melee" and (policy.meleeMultiplier or 1)
        or kind=="slam" and (policy.explosionMultiplier or 1) or 1)
    -- Conservatively include the head multiplier; an uncertain lethal contact
    -- waits for authority instead of predicting a living fall over a death.
    if kind=="melee" then multiplier=multiplier*math.max(1,policy.headshotMultiplier or 1) end
    if not finite(multiplier) or multiplier<0 then return deny("damage_policy") end
    local entity=Open77.players.entity(victim)
    if not entity then return deny("unstreamed") end
    -- Asked last, so a skip counts only a fall that would really have been
    -- predicted. Not remembered as a contact: nothing was presented.
    local verdict=gate(kind,session)
    if verdict then return skip(kind,verdict) end
    local handle,reason=Open77.motion.predictAction(kind,entity,x,y,damage*multiplier)
    contacts[key]={expiry=stamp+3000,handle=handle,kind=kind,action=tostring(action),victim=victim}
    return handle,reason
end
-- `skipped` is per family: the predictions the server policy stopped before
-- they started (open77_prediction folds it into its telemetry).
exports("motionPredictionStats",function()
    return {refused=refused,skipped=skipped,native=Open77.motion.predictionStats()}
end)
AddEventHandler("open77_prediction:hack",function(victim,action,x,y,damage)
    CyberwarePrediction.request("hack",victim,action,x,y,damage)
end)

-- Retain the contact-time candidates, as the server does. Re-selecting on
-- impact predicts people who moved into the radius or away from their evidence.
function CyberwarePrediction.slamContact(config,action,origin)
    slamContact=nil
    if not policy or policy.enabled~=true or type(config)~="table" or not point(origin)
        or not finite(config.radius) or config.radius<=0 or config.radius>12 then return end
    local candidates={}
    for _,target in ipairs(Open77.players.nearby(config.radius,{origin=origin,limit=4}) or {}) do
        local life=Open77.players.getLifeState(target.playerId)
        if point(target.position) and life then
            candidates[#candidates+1]={playerId=target.playerId,
                position={x=target.position.x,y=target.position.y,z=target.position.z},
                revision=life.revision,bucket=life.bucket}
        end
    end
    slamContact={action=action,origin={x=origin.x,y=origin.y,z=origin.z},targets=candidates,expires=now()+2500}
end
local function distanceSquared(a,b) return (a.x-b.x)^2+(a.y-b.y)^2+(a.z-b.z)^2 end
-- One bounded geometry pass on impact, following the server's ray order and
-- validation tolerances. Missing evidence gives no speculative fall.
function CyberwarePrediction.slam(config,action,impact)
    local contact=slamContact
    slamContact=nil
    if not contact or contact.action~=action or now()>=contact.expires or not point(impact)
        or distanceSquared(impact,contact.origin)>0.75^2 then return end
    local origin=contact.origin
    if not policy or policy.enabled~=true or type(config)~="table" or config.reaction~="knockdown"
        or not finite(config.knockbackMeters) or config.knockbackMeters<=0
        or not finite(config.maxFloorDelta) then return end
    local budget=32
    local function ray(a,b)
        if budget==0 then return end
        budget=budget-1
        return Open77.world.raycast(a,b,{static=true,dynamic=true})
    end
    local function floorAt(p)
        local a,b={x=p.x,y=p.y,z=p.z+0.3},{x=p.x,y=p.y,z=p.z-0.8}
        local hit=ray(a,b)
        if not hit or hit.hit~=true or not point(hit.position) or not point(hit.normal)
            or not finite(hit.distance) or hit.distance<0 then return end
        local n=hit.normal
        if math.abs(math.sqrt(n.x*n.x+n.y*n.y+n.z*n.z)-1)>0.1 or n.z<0.45 or n.z>1.01
            or math.abs(hit.position.x-p.x)>0.05 or math.abs(hit.position.y-p.y)>0.05
            or hit.position.z<p.z-0.82 or hit.position.z>p.z+0.32
            or math.abs(math.sqrt(distanceSquared(a,hit.position))-hit.distance)>0.1 then return end
        return hit.position.z
    end
    local originFloor=floorAt(origin)
    if not originFloor then return end
    local damage=math.min(300,(config.damage or 0)+(config.maxHeight or 0)*(config.heightBonusPerMeter or 0))
    if config.cosmetic or config.nonlethal then damage=0 end
    for _,target in ipairs(contact.targets) do
        local p,current=target.position,playerPosition(target.playerId)
        local life=Open77.players.getLifeState(target.playerId)
        if point(current) and life and life.revision==target.revision and life.bucket==target.bucket
            and distanceSquared(p,current)<=0.75^2 and math.abs(p.z-origin.z)<=config.maxFloorDelta then
            local dx,dy=p.x-origin.x,p.y-origin.y
            local steps=math.max(1,math.ceil(math.sqrt(dx*dx+dy*dy)))
            if budget<steps+1 then break end
            local floor=floorAt(p)
            local line=ray({x=origin.x,y=origin.y,z=origin.z+0.5},{x=p.x,y=p.y,z=p.z+0.5})
            local clear=floor and math.abs(floor-originFloor)<=config.maxFloorDelta
                and math.abs(floor-originFloor)<=1 and line and line.hit==false
            -- Server order: origin floor, target floor, line, supports 1..N.
            local previous=floor
            if clear then
                for i=1,steps-1 do
                    local t=i/steps
                    local support=floorAt({x=origin.x+dx*t,y=origin.y+dy*t,z=origin.z+(p.z-origin.z)*t})
                    if not support or math.abs(support-previous)>1 then clear=false;break end
                    previous=support
                end
            end
            if clear then CyberwarePrediction.request("slam",target.playerId,action,dx,dy,damage) end
        end
    end
end
