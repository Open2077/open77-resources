-- Only the server grants a reflex overdrive. This resource does not define
-- loadouts, and it changes no clock: `Open77.reflex.overdrive` applies stat
-- modifiers on the local body and nothing else. The shared world keeps running
-- at normal speed for everyone, this player included -- what changes is how
-- fast this player's own body moves and acts. No bullet is slowed, no other
-- player is slowed, and there is no time domain of any kind here.
local PREFIX = "open77:reflex:"
local nonce = string.format("%016x%016x", math.floor(Open77.time.monotonic()*1000000), math.random(0,2147483647))
local projection, pending, active
-- The activation lease. Held, a press engages the boost on the frame the player
-- pressed and the server is told afterwards; the server's deadline still
-- governs when the boost must end, and the client policy still clamps to its
-- own 15 s cap. Not held, the original permit path runs unchanged.
local lease
local revision, stopped, lastSnapshot, sequence = 0, false, -10000, 0
-- Declared here because `clear()` below calls it and Lua resolves a local
-- only from its declaration onward; declared later it would be a nil global.
local markerAllOff
local function now() return Open77.time.monotonic()*1000 end
local function finite(n) return type(n)=="number" and n==n and math.abs(n)<math.huge end
local function integer(n, cap) return finite(n) and n>=0 and n%1==0 and n<=cap end
local function token(s) return type(s)=="string" and #s==32 and s:match("^%x+$")~=nil end
local function emit(name, data) TriggerServerEvent(PREFIX..name, data) end
local function session() return Open77.network.status() end
local function body()
    local s=Open77.character.state()
    if s and s.attached and s.alive and not s.inWorkspot and s.vehicle and not s.vehicle.mounted then return s end
end
local function ack(p, ok) emit("projectionResult", {incarnation=p.incarnation,revision=p.revision,ok=ok}) end
local function phase(name)
    local p=projection
    if not p or not active or not active.activation then return end
    active.lastPhase=(active.lastPhase or 0)+1
    emit("nativePhase",{incarnation=p.incarnation,activation=active.activation,sequence=active.lastPhase,phase=name})
end
--- Drops whatever this resource holds FOR THE LOCAL CASTER. The client primitive
--- releases on its own deadline and on death, vehicle, workspot and session
--- change; this only makes sure a resource stop or a lost projection does not
--- leave the boost behind.
---
--- It must NOT touch the observer-side markers. It used to, and that was the
--- "plate goes white two seconds into the boost" defect measured 2026-09-15:
--- an observer holds no grant, so her own projection arrives as `absent`, the
--- revision test passes trivially from zero, `clear()` runs -- and took every
--- plate she was holding for OTHER players with it. Two unrelated roles, one
--- teardown. The plates now drop only on an explicit `off`, on resource stop,
--- or on leaving the session (below).
local function clear()
    lease=nil
    if active then phase("cancelled") end
    pending, active = nil, nil
    Open77.reflex.clear()
    projection=nil
end
local keys={}
for k in ("space enter return tab shift ctrl control alt capslock backspace insert delete home end pageup pagedown up down left right"):gmatch("%S+") do keys[k]=true end
local function validKey(k)
    return type(k)=="string" and (keys[k] or k:match("^[a-z0-9]$") or k:match("^f[1-9]$") or k:match("^f1[0-2]$"))
end
RegisterNetEvent(PREFIX.."projection",function(v)
    local net=session()
    if stopped or type(v)~="table" or not net or v.player~=net.playerId or not integer(v.revision,9007199254740991) then return end
    if v.status=="absent" then
        if v.revision>=revision then revision=v.revision;clear() end
        return
    end
    if not token(v.incarnation) or v.revision<revision then return end
    if v.status=="ready" then return end
    local removed=type(v.status)=="string" and v.status~="pending" and v.definition==nil
    if v.status~="pending" and not removed then return end
    if projection and projection.revision==v.revision and projection.incarnation==v.incarnation then
        if removed then clear() else ack(projection,true) end
        return
    end
    if v.revision<=revision then return end
    revision=v.revision;clear()
    if removed then return end
    local d=v.definition;local c=type(d)=="table" and d.config
    -- The client owns the stat plans and their ceilings; a definition may pick a
    -- tier and an economy, never a modifier. Anything else is refused here.
    if type(d)~="table" or d.profile~="reflex_overdrive" or type(c)~="table"
        or (c.tier~="reflex" and c.tier~="reflex_heavy") or not validKey(c.inputKey)
        or not integer(c.durationMs,15000) or c.durationMs<500
        or (c.presentation~="native" and c.presentation~="silent" and c.presentation~="none") then ack(v,false);return end
    local s=body()
    projection={incarnation=v.incarnation,revision=v.revision,config=c,body=s and s.engineId}
    ack(projection,true)
end)
-- A remaining lifetime; the session clock is frozen at the Welcome packet.
local function leaseTtl(ttlMs)
    if not finite(ttlMs) then return end
    local ttl=math.floor(ttlMs)
    if ttl<=0 or ttl>30000 then return end
    return ttl
end
RegisterNetEvent("open77:leases:grant",function(v)
    if stopped or type(v)~="table" or v.ability~="reflex_overdrive" then return end
    if not projection or v.incarnation~=projection.incarnation then return end
    local ttl=leaseTtl(v.ttlMs);if not ttl then return end
    lease={id=v.leaseId,epoch=v.epoch or 0,budget=v.budget or 1,remaining=v.budget or 1,
        deadline=now()+ttl,sequence=0}
end)
RegisterNetEvent("open77:leases:refresh",function(v)
    if stopped or type(v)~="table" or v.ability~="reflex_overdrive" or not lease then return end
    if v.leaseId~=lease.id or v.epoch~=lease.epoch then return end
    local ttl=leaseTtl(v.ttlMs);if not ttl then return end
    local remaining=tonumber(v.remaining) or 0
    if remaining<0 then remaining=0 elseif remaining>lease.budget then remaining=lease.budget end
    lease.remaining=remaining
    local deadline=now()+ttl
    if deadline>lease.deadline then lease.deadline=deadline end
end)
RegisterNetEvent("open77:leases:revoke",function(v)
    if type(v)~="table" or v.ability~="reflex_overdrive" then return end
    lease=nil
end)
local function spendable()
    if not lease or lease.remaining<=0 then return false end
    local net=session()
    if not net or net.phase~="active" then return false end
    return now()<lease.deadline
end
RegisterNetEvent(PREFIX.."permit",function(v)
    local p,item=projection,pending
    if stopped or not p or not item or type(v)~="table" or v.incarnation~=p.incarnation
        or v.revision~=p.revision or v.sequence~=item.sequence then return end
    local leased=item.leased==true
    pending=nil
    if leased then
        -- The boost is already running. This permit either binds the
        -- authoritative activation id it must quote when reporting phases, or
        -- refuses -- and a refusal releases the boost, which is the correction.
        if not active or not active.leased then return end
        if type(v.ok)~="boolean" or not v.ok or not token(v.activation) then
            Open77.reflex.clear();active=nil;return
        end
        active.activation=v.activation
        if integer(v.durationMs,15000) and v.durationMs>0 then active.deadline=now()+v.durationMs end
        phase("applied")
        return
    end
    if type(v.ok)~="boolean" or not v.ok then return end
    if not token(v.activation) or not integer(v.durationMs,15000) or v.durationMs==0
        or (v.tier~="reflex" and v.tier~="reflex_heavy") then return end
    local s=body()
    if not s or s.engineId~=p.body or now()>=item.deadline then return end
    active={activation=v.activation,lastPhase=0,deadline=now()+v.durationMs}
    -- The server's remaining milliseconds; the client's own policy clamps them
    -- to its 15 s cap and owns every release path from here.
    local request=Open77.reflex.overdrive(v.tier,v.durationMs)
    if not request then phase("rejected");active=nil;return end
    active.request=request
    phase("applied")
end)
--- The nameplate marker: the half of the observer presentation that survives
--- distance.
---
--- Measured 2026-09-15 from a second client on open ground: the attached
--- particles read clearly at 4 m and 10 m and are gone by 20 m. The plate is
--- projected from the head and drawn natively at any distance the viewer allows,
--- so it carries the cue the particles cannot, and the two together mean a
--- boosted player is readable both across a room and across a street.
---
--- Three rules this obeys rather than fights.
--- The plate belongs to whichever resource claimed it FIRST -- `Api::Nameplates`
--- answers `owned_by_another_resource` to everyone else -- so a server already
--- driving nameplates keeps them and this does nothing at all. Refusing loudly
--- once and then staying quiet matters because a boost repeats.
--- The local player is never marked: he is not an observer of himself, and his
--- own plate is not drawn.
--- The label is plain ASCII. The native overlay draws talking state as geometry
--- precisely because a glyph is not guaranteed, so a symbol here could render as
--- nothing on somebody else's font stack.
local MARKER_COLOR = "#FFB020"
local marked, markerComplained = {}, false
local function markerOff(player)
    if not marked[player] then return end
    marked[player] = nil
    pcall(Open77.nameplates.remove, player)
end
markerAllOff = function()
    for player in pairs(marked) do pcall(Open77.nameplates.remove, player) end
    marked = {}
end
RegisterNetEvent("open77_reflex:marker", function(v)
    if stopped or type(v) ~= "table" then return end
    local player = tonumber(v.player)
    local net = session()
    if not player or player <= 0 or player % 1 ~= 0 then return end
    if net and net.playerId == player then return end
    if v.on ~= true then markerOff(player); return end
    if type(v.name) ~= "string" or v.name == "" then return end
    if type(Open77.nameplates) ~= "table" or type(Open77.nameplates.set) ~= "function" then return end
    -- 96 bytes is the native ceiling; the suffix is what must survive a long
    -- name, so the NAME is trimmed rather than the cue.
    local suffix = " // OVERDRIVE"
    local label = v.name:sub(1, 96 - #suffix) .. suffix
    local ok, reason = Open77.nameplates.set(player, {
        label = label, color = MARKER_COLOR, maxDistance = 250, visible = true,
    })
    if ok then
        marked[player] = true
    elseif not markerComplained then
        markerComplained = true
        print(("[open77_reflex] nameplate marker unavailable (%s); the attached effects still play")
            :format(tostring(reason)))
    end
end)

RegisterNetEvent(PREFIX.."phase",function(v)
    -- Presentation hook for observers. Deliberately silent for now: the native
    -- grade and trails of the vanilla Sandevistan are consequences of a slowed
    -- simulation and of NPC-bound effect bindings, neither of which is reusable
    -- here (docs/research/native-sandevistan.md). An owner-authored presentation
    -- belongs in a server resource, through the existing effects API.
    --
    -- What this DOES own is the authority ending a boost this client is running.
    -- `cancel` is the admin and counterplay path, and before this it did nothing
    -- at all: measured 2026-09-15, a cancel sent 2.5 s into a 6 s boost left the
    -- body boosted for the remaining 4.5 s -- full speed, attack speed and
    -- evasion -- while the server had already recorded `cancelled` and stopped
    -- believing in the activation. The ledger and the body must never be able to
    -- disagree about whether a player is boosted.
    --
    -- Only `cancelled`, and only for this client's own live activation.
    -- `completed` is the deadline the primitive owns and reaches by itself, and
    -- every other phase belongs to somebody else's body. Clearing `active`
    -- before releasing is deliberate: the release must not report a cancellation
    -- back to the authority that just ordered it.
    if stopped or type(v)~="table" or v.phase~="cancelled" then return end
    local net=session()
    if not net or v.player~=net.playerId then return end
    if not active or not token(v.activation) or v.activation~=active.activation then return end
    active=nil
    Open77.reflex.clear()
end)
-- Declared ahead of `step`, which binds the server's default key every frame
-- (cheaply: a no-op once bound) and is defined before the mapping code below.
local bindKey
local function step(p)
    bindKey(p.config.inputKey)
    local s=body()
    if not s or s.engineId~=p.body then clear();return end
    local state=Open77.reflex.state()
    if active then
        -- The primitive released on its own -- deadline, death, vehicle,
        -- workspot, session change -- so the server hears about it once.
        if not state or state.active~=true or state.request~=active.request then
            phase("released");active=nil
        end
        return
    end
    if pending and now()>=pending.deadline then pending=nil end
end
--- The activation itself, on the key-down edge of the `reflex_overdrive`
--- mapping. This used to be a per-frame `Open77.input.isDown` poll of the
--- server's `inputKey`, which no player could change; the owner asked for the
--- same rebindable action hacking has. The engine now owns the edge, the
--- suppression while a page holds the keyboard, and the player's saved rebind
--- (Pause > Settings > KEY BINDINGS, remembered across servers); the server's
--- `inputKey` is only the default the mapping is registered with.
local function engage(p)
    if stopped or active or pending then return end
    if Open77.input.isCaptured()~=false then return end
    sequence=sequence+1
    if spendable() then
        -- Engage on this very frame, from the tier and duration the projection
        -- already carried and the client already validated. The 1500 ms intent
        -- window that used to expire before the permit came back now gates
        -- nothing: the permit that follows only confirms, and a refusal reaches
        -- the ordinary release path.
        local request=Open77.reflex.overdrive(p.config.tier,p.config.durationMs)
        if not request then return end
        lease.remaining=lease.remaining-1
        lease.sequence=lease.sequence+1
        local net=session()
        -- No activation id yet; `active.activation` binds when the permit lands,
        -- and nothing is reported under a made-up id in the meantime.
        active={activation=nil,request=request,lastPhase=0,deadline=now()+p.config.durationMs,leased=true}
        pending={sequence=sequence,deadline=now()+8000,leased=true}
        emit("report",{
            report={lease=lease.id,epoch=lease.epoch,sequence=lease.sequence,ageMs=0,
                clientTimeMs=math.floor(now())},
            intent={incarnation=p.incarnation,revision=p.revision,sequence=sequence}})
        return
    end
    pending={sequence=sequence,deadline=now()+1500}
    emit("intent",{incarnation=p.incarnation,revision=p.revision,sequence=sequence})
end
local MAPPING, boundKey = "reflex_overdrive", nil
bindKey = function(key)
    key = type(key)=="string" and key:upper() or "X"
    if key==boundKey then return end
    -- Re-registering the same id replaces the entry and keeps the player's
    -- rebind, so a server that ships a different default never overrides a
    -- key the player chose.
    local ok, detail = RegisterKeyMapping(MAPPING, "Overdrive: engage the reflex boost", key, function()
        if projection then engage(projection) end
    end)
    -- One line per registration, so a refused mapping is a log line rather than
    -- a dead key: the effective key is the player's rebind when one exists.
    print(("[open77_reflex] key mapping %s: %s (%s)"):format(MAPPING, ok and "registered" or "refused", tostring(detail)))
    if ok then boundKey=key end
end
bindKey("X")
exports("capabilities",function()
    return {profile="reflex_overdrive",sharedRealTimeWorld=true,slowsBullets=false,slowsOtherPlayers=false,
        touchesTimeDilation=false,maximumDurationMs=15000,
        projection=projection and "ready" or "absent",visualProof=false}
end)
exports("state",function()
    local value=Open77.reflex.state();if not value then return nil end
    return {phase=value.phase,kind=value.kind,remainingMs=value.remainingMs,reason=value.reason}
end)
CreateThread(function()
    while not stopped do
        local net=session()
        if net and net.phase=="active" then
            if now()-lastSnapshot>=2000 then lastSnapshot=now();emit("snapshot",{nonce=nonce}) end
            if projection then step(projection) end
        else
            if projection then clear() end
            -- Out of a session there is nobody to label; the roster the plates
            -- were raised against is gone with it.
            markerAllOff()
            revision=0;lastSnapshot=-10000
        end
        Wait(0)
    end
end)
AddEventHandler("onResourceStop",function(name)
    if name~=GetCurrentResourceName() then return end
    stopped=true;clear();markerAllOff()
end)
