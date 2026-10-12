-- Only the server grants native movement. This resource does not define loadouts.
local PREFIX = "open77:dash:"
local function newNonce()
    return string.format("%016x%016x", math.floor(Open77.time.monotonic()*1000000), math.random(0,2147483647))
end
local nonce = newNonce()
local projection, pending, active, correction
-- The activation lease.
--
-- Held, a press is spent locally and the dash runs on the frame the player
-- pressed; the server is told afterwards and reconciles at the stamp it was
-- given. `binding` is a dash already running locally whose authoritative
-- activation id has not come back yet -- the client uses that id to report
-- phases, it never waits for it to move.
--
-- Not held, the original permit path runs unchanged, so a server that issues no
-- lease behaves exactly as before.
local lease, binding
local revision, keyHeld, stopped, lastSnapshot = 0, true, false, -10000
local lastTerminal, draining
local resyncPending = false
local function now() return Open77.time.monotonic()*1000 end
local function finite(n) return type(n)=="number" and n==n and math.abs(n)<math.huge end
local function integer(n, cap) return finite(n) and n>=0 and n%1==0 and n<=cap end
local function token(s) return type(s)=="string" and #s==32 and s:match("^%x+$")~=nil end
local function native(op, ...) return Open77.dash.call(op, ...) end
local function emit(name, data) TriggerServerEvent(PREFIX..name, data) end
local function session() return Open77.network.status() end
local function body()
    local s=Open77.character.state()
    if s and s.attached and s.alive and not s.inWorkspot and s.vehicle and not s.vehicle.mounted then return s end
end
local function ack(p, ok) emit("projectionResult", {incarnation=p.incarnation,revision=p.revision,ok=ok}) end
local function terminal(item, incarnation, needsDrain)
    local t={activation=item.activation,incarnation=incarnation,request=item.request,
        sequence=item.sequence,lastPhase=item.lastPhase or 0,deadline=now()+1500,
        body=projection and projection.body}
    lastTerminal=t
    if needsDrain then draining=t end
    return t
end
local function pollDrain()
    local t=draining
    if not t then return end
    if now()>t.deadline then draining=nil;return end
    local s=Open77.character.state()
    if not s or not s.attached or s.engineId~=t.body then draining=nil;return end
    -- A failed/missing activity read is not evidence of native cleanup.
    local value=native("activity")
    if not value or value.request~=t.request or value.sequence~=t.sequence or value.nativeActive~=false then return end
    if correction and correction.terminal==t then return end
    local phase=t.lastPhase
    for _,receipt in ipairs(value.history or {}) do
        if receipt.sequence==t.sequence then phase=math.max(phase,receipt.phaseSequence) end
    end
    phase=math.max(phase,value.phaseSequence or 0)+1
    emit("nativePhase",{incarnation=t.incarnation,activation=t.activation,sequence=phase,phase="drained"})
    t.drained=true;draining=nil
end
local function cancel()
    local item=active or pending or binding
    if item then native("cancel",item.request,item.sequence) end
    pending,active,binding=nil,nil,nil
end
local function clear()
    local net=session()
    if active and projection and net and net.phase=="active" then
        active.lastPhase=(active.lastPhase or 0)+1
        emit("nativePhase",{incarnation=projection.incarnation,activation=active.activation,
            sequence=active.lastPhase,phase="cancelled"})
        terminal(active,projection.incarnation,true)
    end
    cancel();native("release");projection=nil;correction=nil;lastTerminal=nil;keyHeld=true
    lease=nil;binding=nil
end
local keys={}
for k in ("space enter return tab shift ctrl control alt capslock backspace insert delete home end pageup pagedown up down left right"):gmatch("%S+") do keys[k]=true end
local function validKey(k)
    return type(k)=="string" and (keys[k] or k:match("^[a-z0-9]$") or k:match("^f[1-9]$") or k:match("^f1[0-2]$"))
end
local function resync(reason)
    if resyncPending then return end
    print("[dash] requesting fresh projection: " .. tostring(reason))
    clear()
    -- Use the existing projector-restart handshake. Only the server can issue
    -- the new revision; its charges/cooldown and movement authority survive.
    nonce=newNonce();lastSnapshot=-10000;resyncPending=true
end
RegisterNetEvent("open77:dashInspect",function()
    local value, reason = native("activity")
    print(("[dash] projection=%s ready=%s request=%s pending=%s active=%s binding=%s draining=%s captured=%s native=%s nativeActive=%s sequence=%s reason=%s"):format(
        tostring(projection ~= nil), tostring(projection and projection.ready), tostring(projection and projection.request),
        tostring(pending ~= nil), tostring(active ~= nil), tostring(binding ~= nil), tostring(draining ~= nil),
        tostring(Open77.input.isCaptured()), tostring(value and value.phase), tostring(value and value.nativeActive),
        tostring(value and value.sequence), tostring(reason or (value and value.reason))))
end)
RegisterNetEvent(PREFIX.."projection",function(v)
    local net=session()
    if stopped or type(v)~="table" or not net or v.player~=net.playerId or not integer(v.revision,9007199254740991) then return end
    if v.status=="absent" then
        if v.revision>=revision then revision=v.revision;clear();resyncPending=false end
        return
    end
    if not token(v.incarnation) or v.revision<revision then return end
    if v.status=="ready" then
        -- A transient body/workspot loss can clear the local projection after
        -- its original acknowledgement. The server ignores a late failure ack
        -- for an already-ready grant, so simply ignoring snapshots deadlocks it.
        if not projection and body() then resync("local_projection_lost") end
        return
    end
    local removed=type(v.status)=="string" and v.status~="pending" and v.definition==nil
    if v.status~="pending" and not removed then return end
    if projection and projection.revision==v.revision and projection.incarnation==v.incarnation then
        if removed then clear()
        elseif projection.ready then ack(projection,true)
        elseif projection.failed then ack(projection,false) end
        return
    end
    if v.revision<=revision then return end
    revision=v.revision;clear();resyncPending=false
    if removed then return end
    local d=v.definition;local c=type(d)=="table" and d.config
    if type(d)~="table" or d.profile~="dash" or type(c)~="table" or not validKey(c.inputKey)
        or type(c.allowGround)~="boolean" or type(c.allowAir)~="boolean" or not(c.allowGround or c.allowAir)
        or c.movementProfile~="native" or (c.presentation~="native" and c.presentation~="silent" and c.presentation~="none")
        or not finite(c.maxFallSpeed) or c.maxFallSpeed<0.1 or c.maxFallSpeed>30 then ack(v,false);return end
    projection={incarnation=v.incarnation,revision=v.revision,config=c,deadline=now()+10000}
end)
-- A REMAINING LIFETIME, never an absolute deadline: the session's
-- `serverTimeMicroseconds` is frozen at the Welcome packet and never advances,
-- so a deadline derived from it discards every lease within seconds.
local function leaseTtl(ttlMs)
    if not finite(ttlMs) then return end
    local ttl=math.floor(ttlMs)
    if ttl<=0 or ttl>30000 then return end
    return ttl
end
RegisterNetEvent("open77:leases:grant",function(v)
    if stopped or type(v)~="table" or v.ability~="dash" then return end
    if not projection or v.incarnation~=projection.incarnation then return end
    local ttl=leaseTtl(v.ttlMs);if not ttl then return end
    lease={id=v.leaseId,epoch=v.epoch or 0,budget=v.budget or 1,remaining=v.budget or 1,
        deadline=now()+ttl,sequence=0}
end)
RegisterNetEvent("open77:leases:refresh",function(v)
    if stopped or type(v)~="table" or v.ability~="dash" or not lease then return end
    if v.leaseId~=lease.id or v.epoch~=lease.epoch then return end
    local ttl=leaseTtl(v.ttlMs);if not ttl then return end
    -- A refresh restores what the server says is legitimate NOW and may never
    -- raise the budget above the grant, nor pull an extended deadline back.
    local remaining=tonumber(v.remaining) or 0
    if remaining<0 then remaining=0 elseif remaining>lease.budget then remaining=lease.budget end
    lease.remaining=remaining
    local deadline=now()+ttl
    if deadline>lease.deadline then lease.deadline=deadline end
end)
RegisterNetEvent("open77:leases:revoke",function(v)
    if type(v)~="table" or v.ability~="dash" then return end
    lease=nil
end)
local function spendable()
    if not lease or lease.remaining<=0 then return false end
    local net=session()
    if not net or net.phase~="active" then return false end
    return now()<lease.deadline
end
RegisterNetEvent(PREFIX.."permit",function(v)
    local p=projection
    -- The leased path: the dash is already running. This permit only carries the
    -- authoritative activation id it must quote when reporting phases, or the
    -- refusal that cancels it -- which is the existing correction path, reached
    -- without ever having waited for it.
    local waiting=binding
    if waiting and p and type(v)=="table" and v.incarnation==p.incarnation
        and v.revision==p.revision and v.sequence==waiting.sequence then
        binding=nil
        if v.ok==true and token(v.activation) then
            waiting.activation=v.activation;active=waiting
            local buffered=waiting.pending or {}
            waiting.pending=nil
            for _,receipt in ipairs(buffered) do
                if active then
                    emit("nativePhase",{incarnation=p.incarnation,activation=waiting.activation,
                        sequence=receipt.sequence,phase=receipt.phase})
                    if receipt.phase~="started" then
                        terminal(active,p.incarnation,receipt.phase~="completed")
                        active=nil
                    end
                end
            end
        else
            native("cancel",waiting.request,waiting.sequence)
            if active==waiting then active=nil end
        end
        return
    end
    local item=pending
    if stopped or not p or not item or type(v)~="table" or v.incarnation~=p.incarnation
        or v.revision~=p.revision or v.sequence~=item.sequence then return end
    pending=nil
    local s=body()
    if not s or s.engineId~=p.body or now()>=item.deadline or type(v.ok)~="boolean" then native("cancel",item.request,item.sequence);return end
    if v.ok and (not token(v.activation) or not integer(v.expiresInMs,750) or v.expiresInMs==0
        or not finite(v.directionX) or not finite(v.directionY)
        or math.abs(v.directionX-item.dx)>0.001 or math.abs(v.directionY-item.dy)>0.001) then native("cancel",item.request,item.sequence);return end
    if v.ok then item.activation=v.activation;item.lastPhase=0;active=item end
    local ok=native("approve",item.request,item.sequence,v.ok)
    if not ok and active then
        emit("nativePhase",{incarnation=p.incarnation,activation=active.activation,sequence=1,phase="rejected"})
        active.lastPhase=1;terminal(active,p.incarnation,true)
        cancel()
    end
end)
RegisterNetEvent(PREFIX.."phase",function(v)
    if stopped or type(v)~="table" or not token(v.activation) or not token(v.incarnation) then return end
    local net=session();if not net or net.phase~="active" then return end
    if v.phase=="started" then
        local serverNow=(net.serverTimeMicroseconds or 0)/1000
        if not finite(v.expiresAtMs) or not finite(v.serverTimeMs) or serverNow>v.expiresAtMs then return end
    end
    if v.phase=="started" or v.phase=="completed" or v.phase=="cancelled" or v.phase=="rejected" then
        native("present",v.player,v.activation,v.mode,v.phase,v.directionX,v.directionY,v.presentation)
    end
    if v.player==net.playerId and projection and v.incarnation==projection.incarnation
        and (v.phase=="cancelled" or v.phase=="rejected") then
        if active and v.activation==active.activation then
            terminal(active,v.incarnation,true)
            cancel()
        elseif lastTerminal and v.activation==lastTerminal.activation and v.incarnation==lastTerminal.incarnation
            and now()<=lastTerminal.deadline and not lastTerminal.drained then
            draining=lastTerminal
        end
    end
end)
RegisterNetEvent(PREFIX.."correction",function(v)
    local t=lastTerminal
    if type(v)~="table" or not t or t.corrected or v.activation~=t.activation or v.incarnation~=t.incarnation or now()>t.deadline
        or not finite(v.x) or not finite(v.y) or not finite(v.z) then return end
    if math.abs(v.x)>1000000 or math.abs(v.y)>1000000 or math.abs(v.z)>1000000 then return end
    correction={x=v.x,y=v.y,z=v.z,terminal=t}
end)
local function direction(s)
    local view=Open77.camera.view();local f=view and view.forward or s.forward
    if not f or not finite(f.x) or not finite(f.y) then return end
    local len=math.sqrt(f.x*f.x+f.y*f.y);if len<0.01 then return end
    local fx,fy=f.x/len,f.y/len
    local longitudinal=(Open77.input.isDown("forward") and 1 or 0)-(Open77.input.isDown("back") and 1 or 0)
    local lateral=(Open77.input.isDown("strafe_right") and 1 or 0)-(Open77.input.isDown("strafe_left") and 1 or 0)
    if longitudinal==0 and lateral==0 then longitudinal=1 end
    local dx,dy=fx*longitudinal+fy*lateral,fy*longitudinal-fx*lateral
    len=math.sqrt(dx*dx+dy*dy);return dx/len,dy/len
end
local phases={started=true,completed=true,cancelled=true,rejected=true}
local function step(p)
    local s=body()
    if not s or s.engineId~=p.body then ack(p,false);clear();return end
    local value=native("activity")
    if binding and now()>=binding.deadline then
        resync("permit_timeout")
        return
    end
    -- A leased dash is already running while its activation id is still in
    -- flight. Its receipts are collected here and flushed by the permit
    -- handler, because the native history is bounded and would have dropped
    -- them by the time the id arrives at 800 ms.
    if binding and value and value.request==p.request then
        for _,receipt in ipairs(value.history or {}) do
            if receipt.sequence==binding.sequence and receipt.phaseSequence>binding.lastPhase and phases[receipt.phase] then
                binding.lastPhase=receipt.phaseSequence
                binding.pending=binding.pending or {}
                binding.pending[#binding.pending+1]={sequence=receipt.phaseSequence,phase=receipt.phase}
            end
        end
    end
    if active and value and value.request==p.request then
        for _,receipt in ipairs(value.history or {}) do
            if not active then break end
            if receipt.sequence==active.sequence and receipt.phaseSequence>active.lastPhase and phases[receipt.phase] then
                active.lastPhase=receipt.phaseSequence
                emit("nativePhase",{incarnation=p.incarnation,activation=active.activation,sequence=receipt.phaseSequence,phase=receipt.phase})
                if receipt.phase~="started" then
                    -- Retain correlation for a late authority rejection after a
                    -- fast native exit, without inferring any missing entry.
                    terminal(active,p.incarnation,receipt.phase~="completed")
                    active=nil
                end
            end
        end
    end
    if correction then
        local c=correction
        if c.terminal~=lastTerminal or now()>c.terminal.deadline or active or pending then correction=nil
        elseif value and value.request==c.terminal.request and value.sequence==c.terminal.sequence and value.nativeActive==false then
            -- One authority correction after rejected motion; never drives Dash.
            if Open77.travel.teleport(c.x,c.y,c.z,s.yaw or 0) then
                c.terminal.corrected=true;correction=nil
            end
        end
    end
    if pending and now()>=pending.deadline then cancel() end
    local down=Open77.input.isDown(p.config.inputKey)==true
    local rising=down and not keyHeld;keyHeld=down
    if not rising or pending or active or binding or correction or draining or Open77.input.isCaptured()~=false then return end
    local dx,dy=direction(s);if not dx then return end
    local sequence, requestReason=native("request",p.request,dx,dy)
    if not sequence then
        print("[dash] request refused: " .. tostring(requestReason))
        if requestReason=="dash_not_ready" then resync("native_projection_lost") end
        return
    end
    value=native("activity")
    if not value or value.sequence~=sequence or value.request~=p.request or value.phase~="pending" then native("cancel",p.request,sequence);return end
    lastTerminal=nil
    if spendable() then
        -- Spend locally and dash on this frame. No round trip is taken and none
        -- is waited for; the 750 ms window that used to expire before the permit
        -- came back simply has nothing left to expire.
        if not native("approve",p.request,sequence,true) then native("cancel",p.request,sequence);return end
        lease.remaining=lease.remaining-1
        lease.sequence=lease.sequence+1
        local net=session()
        binding={request=p.request,sequence=sequence,dx=value.directionX,dy=value.directionY,lastPhase=0,deadline=now()+3000}
        emit("report",{
            -- ageMs is what the server judges by: it subtracts it from its
            -- own arrival clock, so the one-way delay cancels. Reported in the
            -- same tick as the dash, so it is zero.
            report={lease=lease.id,epoch=lease.epoch,sequence=lease.sequence,ageMs=0,
                clientTimeMs=math.floor(now())},
            intent={incarnation=p.incarnation,revision=p.revision,sequence=sequence,
                mode=value.mode,directionX=value.directionX,directionY=value.directionY}})
        return
    end
    pending={request=p.request,sequence=sequence,dx=value.directionX,dy=value.directionY,deadline=now()+750}
    emit("intent",{incarnation=p.incarnation,revision=p.revision,sequence=sequence,mode=value.mode,directionX=value.directionX,directionY=value.directionY})
end
exports("capabilities",function()
    return {profile="dash",movementProfile="native",maxAirUses=1,standaloneAirDash=true,
        projection=projection and (projection.ready and "ready" or "pending") or "absent",visualProof=false}
end)
exports("activity",function()
    local value=native("activity");if not value then return nil end
    return {phase=value.phase,mode=value.mode,sequence=value.sequence,elapsedMs=value.elapsedMs,reason=value.reason}
end)
CreateThread(function()
    while not stopped do
        local net=session()
        if net and net.phase=="active" then
            if now()-lastSnapshot>=2000 then lastSnapshot=now();emit("snapshot",{nonce=nonce}) end
            local p=projection
            if p and not p.failed then
                if p.ready then step(p)
                elseif now()>=p.deadline then p.failed=true;ack(p,false);native("release")
                else
                    if not p.request then local s=body();if s then p.request=native("configure",p.config.allowGround,p.config.allowAir,p.config.maxFallSpeed,p.config.presentation);p.body=s.engineId end end
                    if p.request then
                        local state=native("state",p.request)
                        if state=="ready" then p.ready=true;ack(p,true)
                        elseif state~="pending" then p.failed=true;ack(p,false);native("release") end
                    end
                end
            end
            pollDrain()
        else
            if projection then clear() end
            draining=nil;revision=0;lastSnapshot=-10000;resyncPending=false
        end
        Wait(0)
    end
end)
AddEventHandler("onResourceStop",function(name)
    if name~=GetCurrentResourceName() then return end
    stopped=true;clear()
end)
