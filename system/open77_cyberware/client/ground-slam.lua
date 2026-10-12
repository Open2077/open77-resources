-- Native action ownership and server-authored geometry only. Entitlement,
-- costs, candidate selection, damage and reactions remain server decisions.
local PREFIX = "open77:abilities:"
local projection, pending, active
-- The activation lease. Held, a slam starts on the frame the player pressed and
-- the server is told afterwards; only the ENTRY is leased -- the terminal
-- commit, the damage and the knockback, stays authoritative on arrival. Not
-- held, the original permit path runs unchanged.
local lease
local draining, lastTerminal
local lastServerError
local highRevision = 0
local keyHeld = true -- require release after grant/reload; never activate a held menu key.
local stopped = false
local geometry, seenGeometry = {}, {}
-- Accepted slams of this client: activation -> prediction key, so the terminal
-- impact verdict (which names only the activation) settles that exact sequence.
local slams = {}
local function now() return Open77.time.monotonic() * 1000 end
local function finite(n) return type(n) == "number" and n == n and math.abs(n) < math.huge end
local function integer(n, max) return finite(n) and n >= 0 and n % 1 == 0 and n <= max end
local function token(s) return type(s) == "string" and #s == 32 and s:match("^%x+$") ~= nil end
local function point(v)
    if type(v) ~= "table" or not finite(v.x) or not finite(v.y) or not finite(v.z)
        or math.abs(v.x)>=1000000 or math.abs(v.y)>=1000000 or math.abs(v.z)>=1000000 then return nil end
    return {x=v.x,y=v.y,z=v.z}
end
local function api() return Open77.abilities end
local function emit(name, value) TriggerServerEvent(PREFIX .. name, value) end
local function localPlayer()
    local status = Open77.network.status()
    return status and status.phase == "active" and status.playerId or nil
end
local function character() return Open77.character.state() end
local function safeBody(state)
    return state and state.attached == true and state.alive == true and not state.inWorkspot
        and state.vehicle and not state.vehicle.mounted
end
local function ack(p, ok, error)
    emit("projectionResult", {incarnation=p.incarnation,revision=p.revision,ok=ok,error=error})
end
local function cancelNative(reason)
    local item = active or pending
    if active then
        active.expires=now()+1500
        draining=active;lastTerminal=active
    end
    if item and item.incarnation then CyberwarePrediction.cancel("slam",item.incarnation..":"..item.sequence) end
    if item and api() then api().cancelSlam(item.request,item.sequence,reason) end
    pending, active = nil, nil
end
local function clear(reason)
    cancelNative(reason)
    if api() then api().releaseSlam() end
    projection = nil
    lastServerError=nil
    keyHeld = true
end
local function failProjection(p, reason)
    if projection ~= p then return end
    p.failed = true
    ack(p,false,reason or "native_projection_failed")
    cancelNative(reason or "projection_failed")
    if api() then api().releaseSlam() end
end
local actionKeys = {}
for key in ("space enter return tab shift ctrl control alt capslock backspace insert delete " ..
    "home end pageup pagedown up down left right"):gmatch("%S+") do actionKeys[key]=true end
local function validKey(key)
    return type(key) == "string" and (#key == 1 and key:match("^[a-z0-9]$") ~= nil
        or actionKeys[key] or key:match("^f[1-9]$") ~= nil or key:match("^f1[0-2]$") ~= nil)
end
RegisterNetEvent(PREFIX .. "projection", function(value)
    if stopped or type(value) ~= "table" or value.player ~= localPlayer()
        or not token(value.incarnation) or not integer(value.revision,9007199254740991)
        or value.revision < highRevision then return end
    if value.status ~= "pending" and value.status ~= "removed" then return end -- ready only confirms ACK.
    if projection and value.revision == projection.revision and value.incarnation == projection.incarnation then
        if value.status == "removed" then clear("grant_removed")
        elseif projection.ready then ack(projection,true)
        elseif projection.failed then ack(projection,false,"native_projection_failed") end
        return
    end
    -- Removed revisions remain tombstones: an equal late pending event cannot
    -- recreate a revoked native grant. New incarnation requires a newer revision.
    if not projection and value.revision <= highRevision then return end
    highRevision = value.revision
    clear("projection_changed")
    if value.status == "removed" or value.definition == nil then return end
    local definition = value.definition
    local config = type(definition) == "table" and definition.config
    if type(definition) ~= "table" or definition.profile ~= "ground_slam" or type(config) ~= "table" then
        ack(value,false,"unsupported_profile");return
    end
    local key = type(config.inputKey) == "string" and config.inputKey:lower() or "g"
    if not validKey(key) or type(config.allowGround) ~= "boolean" or type(config.allowAir) ~= "boolean"
        or not (config.allowGround or config.allowAir) or not integer(config.maxActivationMs,10000)
        or config.maxActivationMs < 1000 then ack(value,false,"invalid_configuration");return end
    projection = {incarnation=value.incarnation,revision=value.revision,key=key,
        reaction=config,
        config={ground=config.allowGround,air=config.allowAir,staminaManaged=true,
            maxDurationMs=config.maxActivationMs,maxFallSpeed=config.maxFallSpeed or 30},
        deadline=now()+10000}
end)
local function session() return Open77.network.status() end
-- A remaining lifetime; the session clock is frozen at the Welcome packet.
local function leaseTtl(ttlMs)
    if not finite(ttlMs) then return end
    local ttl=math.floor(ttlMs)
    if ttl<=0 or ttl>30000 then return end
    return ttl
end
RegisterNetEvent("open77:leases:grant",function(v)
    if stopped or type(v)~="table" or v.ability~="ground_slam" then return end
    if not projection or v.incarnation~=projection.incarnation then return end
    local ttl=leaseTtl(v.ttlMs);if not ttl then return end
    lease={id=v.leaseId,epoch=v.epoch or 0,budget=v.budget or 1,remaining=v.budget or 1,
        deadline=now()+ttl,sequence=0}
end)
RegisterNetEvent("open77:leases:refresh",function(v)
    if stopped or type(v)~="table" or v.ability~="ground_slam" or not lease then return end
    if v.leaseId~=lease.id or v.epoch~=lease.epoch then return end
    local ttl=leaseTtl(v.ttlMs);if not ttl then return end
    local remaining=tonumber(v.remaining) or 0
    if remaining<0 then remaining=0 elseif remaining>lease.budget then remaining=lease.budget end
    lease.remaining=remaining
    local deadline=now()+ttl
    if deadline>lease.deadline then lease.deadline=deadline end
end)
RegisterNetEvent("open77:leases:revoke",function(v)
    if type(v)~="table" or v.ability~="ground_slam" then return end
    lease=nil
end)
local function spendable()
    if not lease or lease.remaining<=0 then return false end
    local net=session()
    if not net or net.phase~="active" then return false end
    return now()<lease.deadline
end
RegisterNetEvent(PREFIX .. "permit", function(value)
    local p, item = projection, pending
    if stopped or not p or not p.ready or not item or not item.sent or type(value) ~= "table"
        or value.incarnation ~= p.incarnation or value.revision ~= p.revision
        or value.sequence ~= item.sequence or item.request ~= p.request then return end
    pending = nil -- terminal decision; duplicates cannot release another input.
    -- A leased slam may already have predicted falls at its local impact; any
    -- refused or unusable permit must refute them (code review #13).
    local function refuse(reason)
        CyberwarePrediction.cancel("slam",p.incarnation..":"..item.sequence)
        api().cancelSlam(item.request,item.sequence,reason)
    end
    local state = character()
    if not safeBody(state) or state.engineId ~= p.body or now() >= item.deadline
        or type(value.ok) ~= "boolean" then
        refuse("stale_permit");return
    end
    if value.ok and (not token(value.activation) or not integer(value.expiresInMs,750)
        or value.expiresInMs == 0) then
        refuse("invalid_permit");return
    end
    lastServerError=nil
    if not value.ok then
        lastServerError=type(value.error)=="string" and value.error:gsub("[%c]"," "):sub(1,128) or "server_rejected"
    end
    if value.ok then
        item.activation=value.activation; item.lastPhase=0
        item.incarnation=p.incarnation;item.body=p.body
        active=item
        local t,count=now(),0
        for id,slam in pairs(slams) do if t>=slam.expires then slams[id]=nil else count=count+1 end end
        -- Longer than the 10 s activation ceiling plus the geometry deadline.
        if count<16 then slams[value.activation]={incarnation=p.incarnation,action=p.incarnation..":"..item.sequence,expires=t+15000} end
    end
    if item.leased then
        -- Already approved locally and already slamming. Refusal is the only
        -- thing left to act on, and it cancels.
        if not value.ok then refuse("server_rejected") end
        return
    end
    local ok = api().approveSlam(item.request,item.sequence,value.ok)
    if not ok then api().cancelSlam(item.request,item.sequence,"native_approval_failed") end
end)
RegisterNetEvent(PREFIX .. "cancel", function(value)
    if type(value) ~= "table" then return end
    local item=active or lastTerminal
    if item and value.incarnation==item.incarnation and value.activation==item.activation then
        CyberwarePrediction.cancel("slam",item.incarnation..":"..item.sequence)
        if integer(value.phaseSequence,4294967295) then item.lastPhase=math.max(item.lastPhase or 0,value.phaseSequence) end
        if active then cancelNative("server_cancelled")
        else draining=item;draining.expires=now()+1500 end
    end
end)
-- The server accepted the slam but will not knock this one target down
-- (geometry, damage veto, lethal, motion arbiter, or a knockdown lease that
-- ended before going active). Sent to the attacker only, once per target per
-- slam; the predicted fall of THAT target in THAT sequence blends back now
-- instead of playing out its pose lease (code review #13). It may arrive
-- before the local impact predicts: the helper then refuses the prediction.
RegisterNetEvent(PREFIX .. "targetRefused", function(value)
    if stopped or type(value)~="table" or not token(value.incarnation) or not token(value.activation)
        or not integer(value.sequence,4294967295) or value.sequence==0
        or not integer(value.target,9007199254740991) or value.target==0 then return end
    CyberwarePrediction.refute("slam",value.incarnation..":"..math.tointeger(value.sequence),value.target)
end)
-- The terminal impact verdict lists every target the server selected. A
-- predicted target it did not select, or whose knockdown did not start, will
-- not fall by this slam; a started knockdown is left to adoption.
RegisterNetEvent(PREFIX .. "result", function(value)
    if stopped or type(value)~="table" or value.phase~="impact" or value.player~=localPlayer()
        or not token(value.activation) or type(value.targets)~="table" then return end
    local slam=slams[value.activation]
    if not slam or value.incarnation~=slam.incarnation then return end
    slams[value.activation]=nil
    local keep={}
    for i,target in ipairs(value.targets) do
        if i>32 then break end
        if type(target)=="table" and integer(target.player,9007199254740991)
            and type(target.motionId)=="string" and #target.motionId>0 then keep[target.player]=true end
    end
    CyberwarePrediction.refuteExcept("slam",slam.action,keep)
end)

local function drainStep()
    if lastTerminal and now()>=(lastTerminal.expires or 0) then lastTerminal=nil end
    local item=draining
    if not item then return end
    local state=character()
    if not localPlayer() or not safeBody(state) or state.engineId~=item.body or now()>=item.expires then draining=nil;return end
    local value=api() and api().slamActivity()
    -- Missing/foreign native state is not cleanup evidence. Resource release may
    -- erase its receipt; the bounded server deadline handles that case.
    if not value or value.request~=item.request or value.sequence~=item.sequence or value.nativeActive~=false then return end
    local phase=math.max(item.lastPhase or 0,integer(value.phaseSequence,4294967295) and value.phaseSequence or 0)
    if phase>=4294967295 then return end
    emit("phase",{incarnation=item.incarnation,activation=item.activation,phaseSequence=phase+1,phase="drained",
        position=point(value.position) or point(state.position) or {x=0,y=0,z=0},grounded=value.grounded==true,
        elapsedMs=integer(value.elapsedMs,15000) and value.elapsedMs or 0,verticalSpeed=finite(value.verticalSpeed) and value.verticalSpeed or 0})
    item.lastPhase=phase+1;draining=nil
end

-- Geometry runs even when this witness has no entitlement. The server selects
-- every endpoint and authenticates nonce, witnesses, body, bucket and expiry.
RegisterNetEvent(PREFIX .. "geometry", function(value)
    if stopped or not localPlayer() or type(value) ~= "table" or not token(value.activation)
        or not token(value.challenge) or not token(value.incarnation) or not integer(value.bucket,4294967295)
        or not integer(value.player,9007199254740991) or not integer(value.expiresInMs,1500)
        or value.expiresInMs < 1 or type(value.rays) ~= "table" or #value.rays < 1
        or #value.rays > 32 or #geometry >= 64 or seenGeometry[value.challenge] then return end
    local rays, ids = {}, {}
    for i, ray in ipairs(value.rays) do
        if type(ray) ~= "table" or type(ray.id) ~= "string" or #ray.id < 1 or #ray.id > 64
            or ids[ray.id] or not point(ray.from) or not point(ray.to)
            or type(ray.static) ~= "boolean" or type(ray.dynamic) ~= "boolean"
            or not (ray.static or ray.dynamic) then return end
        local dx,dy,dz=ray.to.x-ray.from.x,ray.to.y-ray.from.y,ray.to.z-ray.from.z
        if dx*dx+dy*dy+dz*dz > 1600 then return end
        ids[ray.id]=true
        rays[i]={id=ray.id,from=point(ray.from),to=point(ray.to),static=ray.static,dynamic=ray.dynamic}
    end
    local t=now();seenGeometry[value.challenge]=t+10000
    geometry[#geometry+1]={activation=value.activation,challenge=value.challenge,rays=rays,
        results={},next=1,deadline=t+value.expiresInMs}
end)
local function geometryStep()
    local budget=4
    while budget > 0 and #geometry > 0 do
        local item=table.remove(geometry,1)
        if now() < item.deadline then
            local ray=item.rays[item.next]
            local called,result=pcall(Open77.world.raycast,ray.from,ray.to,{static=ray.static,dynamic=ray.dynamic})
            local valid=called and type(result)=="table" and type(result.hit)=="boolean"
            if valid and result.hit then
                valid=point(result.position)~=nil and point(result.normal)~=nil
                    and finite(result.distance) and result.distance>=0
            end
            local zero={x=0,y=0,z=0}
            item.results[#item.results+1]={id=ray.id,status=valid and "ok" or "error",
                hit=valid and result.hit or false,position=valid and result.hit and point(result.position) or zero,
                normal=valid and result.hit and point(result.normal) or zero,
                distance=valid and result.hit and result.distance or 0}
            item.next=item.next+1;budget=budget-1
            if item.next > #item.rays then
                emit("geometryResult",{activation=item.activation,challenge=item.challenge,results=item.results})
            else geometry[#geometry+1]=item end
        end
    end
    for id,expiry in pairs(seenGeometry) do if now()>=expiry then seenGeometry[id]=nil end end
end
-- Diagnostics execute in the owning support VM. Return a fresh value and no
-- native request handle, so a lab cannot accidentally read another VM's lease.
exports("slamActivity",function()
    local p=projection
    if not p or not p.ready or p.failed or not api() then return nil,"slam_not_ready" end
    local value,reason=api().slamActivity()
    if not value or value.request~=p.request then return nil,reason or "slam_not_ready" end
    return {phase=value.phase,mode=value.mode,reason=value.reason,lastServerError=lastServerError,sequence=value.sequence,
        phaseSequence=value.phaseSequence,impactSequence=value.impactSequence,elapsedMs=value.elapsedMs,
        grounded=value.grounded,verticalSpeed=value.verticalSpeed,nativeActive=value.nativeActive,
        position=point(value.position),contact=point(value.contact)}
end)
local forwarded={windup=true,descent=true,contact=true,impact=true,recovery=true,complete=true,cancelled=true,rejected=true}
local function actionStep(p)
    local state=character()
    if not safeBody(state) or state.engineId~=p.body or not localPlayer() then
        failProjection(p,"body_unavailable");return
    end
    local value,reason=api().slamActivity()
    if not value or value.request~=p.request then
        -- Engine IDs can be recycled across native body replacement. The
        -- owner-scoped native lease, not the numeric entity ID, is definitive.
        failProjection(p,reason or "stale_native_projection");return
    end
    local nativeState,nativeReason=api().slamState(p.request)
    if nativeState~="ready" then failProjection(p,nativeReason or "native_projection_failed");return end
    local intent=active or pending
    if intent and intent.sequence==value.sequence and intent.request==value.request then
        for _,receipt in ipairs(type(value.history)=="table" and value.history or {value}) do
            if receipt.phase=="contact" and p.capturedSequence~=value.sequence and point(receipt.position) then
                p.capturedSequence=value.sequence
                local ok,reason=pcall(CyberwarePrediction.slamContact,p.reaction,p.incarnation..":"..value.sequence,receipt.position)
                if not ok then print("[slam prediction] contact skipped: "..tostring(reason):sub(1,256)) end
            end
            if receipt.phase=="impact" and p.predictedSequence~=value.sequence and point(receipt.position) then
                p.predictedSequence=value.sequence
                -- Optional presentation must never interrupt native phase
                -- forwarding or the authoritative geometry/economy path.
                local ok,reason=pcall(CyberwarePrediction.slam,p.reaction,p.incarnation..":"..value.sequence,receipt.position)
                if not ok then print("[slam prediction] skipped: "..tostring(reason):sub(1,256)) end
                break
            end
        end
    end
    if active and value and value.request==p.request and value.sequence==active.sequence then
        -- Native transitions may happen in one engine frame. Preserve every
        -- bounded receipt and its captured position/time instead of relabeling
        -- the latest state as earlier phases. Reads are nondestructive.
        local receipts=type(value.history)=="table" and #value.history>0 and value.history or {value}
        for i=1,math.min(#receipts,16) do
            local receipt=receipts[i]
            if not active then break end
            if type(receipt)=="table" and integer(receipt.phaseSequence,4294967295)
                and receipt.phaseSequence>active.lastPhase and forwarded[receipt.phase]
                and point(receipt.position) and integer(receipt.elapsedMs,15000)
                and finite(receipt.verticalSpeed) and type(receipt.grounded)=="boolean" then
                active.lastPhase=receipt.phaseSequence
                emit("phase",{incarnation=p.incarnation,activation=active.activation,phaseSequence=receipt.phaseSequence,
                    phase=receipt.phase,position=point(receipt.position),grounded=receipt.grounded,
                    elapsedMs=receipt.elapsedMs,verticalSpeed=receipt.verticalSpeed})
                if receipt.phase=="complete" or receipt.phase=="cancelled" or receipt.phase=="rejected" then
                    active.expires=now()+1500;lastTerminal=active
                    if receipt.phase~="complete" then draining=active end
                    active=nil
                end
            end
        end
    end
    if pending then
        if now()>=pending.deadline then cancelNative("permit_timeout")
        elseif not value or value.request~=pending.request or value.sequence~=pending.sequence then
            cancelNative("stale_native_intent")
        elseif value.phase=="rejected" or value.phase=="cancelled" then
            pending=nil -- failed preflight must never ask the server to spend stamina.
        elseif value.phase=="eligible" and not pending.sent then
            if value.mode~="ground" and value.mode~="air" then cancelNative("invalid_native_intent")
            elseif spendable() then
                -- Leased: approve locally and slam now. The permit that follows
                -- carries the authoritative activation id the phase reports must
                -- quote; a refusal cancels, which is the correction path.
                pending.sent=true;pending.leased=true
                pending.deadline=now()+8000
                lease.remaining=lease.remaining-1
                lease.sequence=lease.sequence+1
                local net=session()
                if api().approveSlam(pending.request,pending.sequence,true) then
                    emit("report",{
                        report={lease=lease.id,epoch=lease.epoch,sequence=lease.sequence,ageMs=0,
                            clientTimeMs=math.floor(now())},
                        intent={incarnation=p.incarnation,revision=p.revision,
                            sequence=pending.sequence,mode=value.mode}})
                else
                    cancelNative("native_approval_failed")
                end
            else
                pending.sent=true
                emit("intent",{incarnation=p.incarnation,revision=p.revision,sequence=pending.sequence,mode=value.mode})
            end
        end
    end
    local down=Open77.input.isDown(p.key)==true
    local rising=down and not keyHeld;keyHeld=down
    if not rising or pending or active or draining or Open77.input.isCaptured()~=false then return end
    local sequence=api().requestSlam(p.request)
    if not sequence then return end
    value=api().slamActivity()
    if not value or value.request~=p.request or value.sequence~=sequence or (value.phase~="pending" and value.phase~="eligible")
        or (value.mode~="ground" and value.mode~="air") then
        api().cancelSlam(p.request,sequence,"invalid_native_intent");return
    end
    -- The incarnation lets a permit timeout refute this sequence's predictions.
    pending={request=p.request,sequence=sequence,deadline=now()+750,incarnation=p.incarnation}
    -- Native preflight is polled above before emitting any cost-bearing intent.
end
CreateThread(function()
    while not stopped do
        drainStep()
        local p=projection
        if p and not p.failed then
            if p.ready then actionStep(p)
            elseif now()>=p.deadline then failProjection(p,"native_grant_timeout")
            elseif not api() then failProjection(p,"api_unavailable")
            else
                if not p.request then
                    local state=character()
                    if safeBody(state) then p.request=api().configureSlam(p.config);p.body=state.engineId end
                end
                if p.request then
                    local phase,reason=api().slamState(p.request)
                    if phase=="ready" then p.ready=true;ack(p,true)
                    elseif phase~="pending" then failProjection(p,reason) end
                end
            end
        end
        if localPlayer() then geometryStep() else geometry={};seenGeometry={} end
        Wait(0)
    end
end)
AddEventHandler("onResourceStop",function(name)
    if name~=GetCurrentResourceName() then return end
    stopped=true;clear("resource_stopped");geometry={};seenGeometry={};slams={}
end)
