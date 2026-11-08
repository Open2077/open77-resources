local C=Aetherfall
-- Two instances of the same arena, each in its own routing bucket: the training grounds (lobby,
-- always open, dummies to practise on) and, while one runs, the duel started from the Conclave
-- menu by the mages of its queue. Each instance has its own rules model and presentation registries.
local function newArena(name,bucket,model)
    return {name=name,bucket=bucket,model=model,fx={},zoneFx={},travel={},wards={}}
end
local lobby=newArena("lobby",C.lobby.bucket,AetherfallDuel.new(C,{practice=true}))
local match=nil
local members,pendingJoin,queue,dummies={}, {}, {}, {}
local stopping=false
local lastSnapshot=0
local function log(text) print("[aetherfall] "..tostring(text)) end
local function notice(id,text) TriggerClientEvent("aetherfall:notice",id,{text=text}) end
local function arenaOf(member) return member and (member.arena=="duel" and match or lobby) or nil end
local function broadcast(arena,event,payload)
    for id,member in pairs(members) do if arenaOf(member)==arena then TriggerClientEvent(event,id,payload) end end
end
local function spawn(index,count)
    local angle=(index-1)*math.pi*2/math.max(2,count)
    local c=C.arena.center
    return {x=c.x+math.sin(angle)*12,y=c.y+math.cos(angle)*12,z=c.z+0.15},(180-angle*180/math.pi)%360
end
-- Training grounds: mages arrive on the south side, facing the dummies (north).
local function lobbySpawn(id)
    local c=C.arena.center
    return {x=c.x+((id%7)-3)*1.6,y=c.y-12,z=c.z+0.15},0
end
local function removeFx(registry,id)
    local handle=registry[id]
    if handle then Open77.effects.remove(handle); registry[id]=nil end
end
local function createFx(effect,position,ttl,bucket)
    local id,reason=Open77.effects.create({effect=effect,position=position,bucket=bucket,
        ttlMs=ttl,streamingRadius=100})
    if not id then log("effect refused "..tostring(reason)) end
    return id
end
-- Spell sounds (shared/sounds.lua, Hogwarts Legacy clips, private): one variant of a moment picked
-- at random, networked in the instance's bucket, its handle released once played (16 per resource).
local Sounds=AetherfallSounds
local liveSounds,liveCount={},0
local function releaseSound(handle)
    if handle and liveSounds[handle] then liveSounds[handle]=nil; liveCount=liveCount-1; DestroySound(handle) end
end
local function spellSound(arena,spellId,moment,position,options)
    local clips=Sounds and Sounds.spells[spellId] and Sounds.spells[spellId][moment]
    if not clips or #clips==0 or not position or liveCount>=14 then return nil end
    local clip=clips[math.random(#clips)]
    local seconds=Sounds.lengths[clip] or 3
    options=options or {}
    local volume=math.max(0,math.min(1,(options.volume or 0.8)*(C.sound and C.sound.volume or 1)))
    local handle,reason=Play3DSound(clip,position,{network=true,bucket=arena.bucket,volume=volume,
        minDistance=options.minDistance or 3,maxDistance=options.maxDistance or 65,duration=seconds})
    if not handle then log("sound refused "..tostring(reason)); return nil end
    liveSounds[handle]=true; liveCount=liveCount+1
    SetTimeout(math.floor(seconds*1000)+500,function() releaseSound(handle) end)
    return handle
end
local function retireWard(arena,player,ended)
    if arena.wards[player] then
        Open77.props.remove(arena.wards[player]); arena.wards[player]=nil
        local p=ended and arena.model.members[player]
        if p and p.position then spellSound(arena,"ward","off",p.position,{volume=0.7,maxDistance=40}) end
    end
end
local function dropWand(member)
    if member.wand then Open77.props.remove(member.wand); member.wand=nil end
    member.nextWandTry=GetGameTimer()+500
end
-- Travel into an instance's bucket; on arrival the mage is ready there (or placed for the round epoch).
local function place(id,arena,position,heading,epoch)
    local member=members[id]; if not member then return end
    member.placement=(member.placement or 0)+1
    local ticket=member.placement
    if arena~=lobby then Open77.players.setFrozen(id,true); member.frozen=true end
    CreateThread(function()
        local result,reason=Open77.players.teleport(id,position,{bucket=arena.bucket,heading=heading,fade=true}):await()
        if stopping or members[id]~=member or member.placement~=ticket or arenaOf(member)~=arena then return end
        if not result then
            notice(id,"Arena travel failed: "..tostring(reason)); arena.model:setReady(id,false)
            member.failed=true
            return
        end
        -- Attachment needs the parent's first accepted post-travel snapshot.
        -- The regular tick retries once that snapshot is available.
        if not member.wand then member.nextWandTry=GetGameTimer()+500 end
        if epoch then arena.model:placed(id,epoch)
        else arena.model:setReady(id,true) end
        log(("placement player=%d arena=%s state=%s epoch=%s"):format(id,arena.name,tostring(result.state),tostring(epoch)))
    end)
end
local function unqueue(id)
    for i=#queue,1,-1 do if queue[i]==id then table.remove(queue,i) end end
end
local function queued(id) for _,q in ipairs(queue) do if q==id then return true end end return false end
-- Back to the training grounds (after a match, a forfeit or a failed start).
local function enterLobby(id)
    local member=members[id]; if not member then return end
    if member.arena=="duel" and match then
        match.model:leave(id); retireWard(match,id)
    end
    member.arena="lobby"; dropWand(member)
    local ok,reason=lobby.model:join(id,Open77.players.name(id))
    if not ok and reason~="already_joined" then notice(id,"Training grounds unavailable: "..tostring(reason)); return end
    Open77.players.setFrozen(id,false); member.frozen=false
    local position,heading=lobbySpawn(id)
    place(id,lobby,position,heading)
end
-- The duelist outfit: a Hogwarts house robe over it when open77_hogwarts_wear has registered them.
local function costumeFor(id)
    local costume=C.costumes[(id-1)%#C.costumes+1]
    local robe=C.robes and C.robes[(id-1)%#C.robes+1]
    if not (robe and Open77.clothing and Open77.clothing.info and Open77.clothing.info(robe)) then return costume end
    local dressed={}
    for slot,record in pairs(costume) do dressed[slot]=record end
    dressed.OuterChest=robe
    return dressed
end

local function join(id,quiet)
    id=tonumber(id)
    if stopping or not id or id<=0 or members[id] then return end
    local read=Open77.players.get(id)
    if not read or not read.ready or not read.alive or not read.position or read.inVehicle then
        if not quiet then notice(id,"Enter the world on foot before joining the Conclave.") end
        return
    end
    -- These buckets are reserved by this server profile. Refuse an occupied foreign activity.
    for _,bucket in ipairs({C.bucket,lobby.bucket}) do
        for _,other in ipairs(Open77.players.inBucket(bucket)) do
            if not members[tonumber(other)] then notice(id,"The arena is occupied by another activity."); return end
        end
    end
    local ok,reason=lobby.model:join(id,Open77.players.name(id))
    if not ok then notice(id,reason); return end
    local selected,selectionError=Open77.locomotion.set(id,C.animationStyle,{resetOnDeath=true})
    if not selected then
        lobby.model:leave(id)
        if not quiet then notice(id,"Casting package unavailable: "..tostring(selectionError)) end
        return
    end
    local dressed,dressError=exports.open77_appearance:setTemporaryOutfit(id,costumeFor(id))
    if not dressed then
        Open77.locomotion.reset(id)
        lobby.model:leave(id)
        if not quiet then notice(id,"Duelist outfit unavailable: "..tostring(dressError)) end
        return
    end
    members[id]={returnPosition=read.position,returnHeading=read.heading or 0,returnBucket=read.bucket,
        nextRequest=0,nextMenu=0,frozen=false,arena="lobby"}
    pendingJoin[id]=nil
    TriggerClientEvent("aetherfall:state",id,lobby.model:snapshot(id))
    local position,heading=lobbySpawn(id)
    place(id,lobby,position,heading)
end
local function leave(id,disconnected)
    id=tonumber(id); pendingJoin[id]=nil; local member=members[id]
    if not member then return end
    unqueue(id)
    local arena=arenaOf(member)
    members[id]=nil; arena.model:leave(id)
    retireWard(arena,id)
    if member.wand then Open77.props.remove(member.wand) end
    exports.open77_appearance:clearTemporaryOutfit(id)
    if disconnected then return end
    Open77.locomotion.reset(id)
    Open77.players.setFrozen(id,false)
    TriggerClientEvent("aetherfall:state",id,{phase="off",roster={}})
    local bucket=Open77.routingBuckets.getPlayer(id)
    if bucket~=C.bucket and bucket~=lobby.bucket then return end
    if stopping then
        -- Native claims/handles are released by resource ownership. A stop handler
        -- cannot keep a coroutine alive to await a streaming transaction.
        Open77.routingBuckets.setPlayer(id,member.returnBucket)
        return
    end
    CreateThread(function()
        local result,reason=Open77.players.teleport(id,member.returnPosition,
            {bucket=member.returnBucket,heading=member.returnHeading,fade=true}):await()
        if not result then
            Open77.routingBuckets.setPlayer(id,member.returnBucket)
            notice(id,"Return travel failed: "..tostring(reason))
        end
    end)
end

-- --- Duels ------------------------------------------------------------------------------------
local function lobbyQueue()
    local present={}
    for _,id in ipairs(queue) do local m=members[id]; if m and m.arena=="lobby" then present[#present+1]=id end end
    return present
end
local function startMatch(starter)
    if match then notice(starter,"A duel is already in progress."); return end
    local ids=lobbyQueue()
    if not queued(starter) then notice(starter,"Join the duel queue first."); return end
    if #ids<C.duel.minPlayers then notice(starter,("%d mages must be in the queue to start a duel."):format(C.duel.minPlayers)); return end
    if #ids>C.maxPlayers then for i=#ids,C.maxPlayers+1,-1 do table.remove(ids,i) end end
    match=newArena("duel",C.bucket,AetherfallDuel.new(C,{finish=true}))
    match.createdAt=GetGameTimer()
    for index,id in ipairs(ids) do
        unqueue(id)
        local member=members[id]
        lobby.model:leave(id); retireWard(lobby,id)
        local ok,reason=match.model:join(id,Open77.players.name(id))
        if ok then
            member.arena="duel"; dropWand(member)
            local position,heading=spawn(index,#ids); place(id,match,position,heading)
            notice(id,"The duel begins: to the Conclave!")
        else
            notice(id,"Could not enter the duel: "..tostring(reason)); lobby.model:join(id,Open77.players.name(id))
        end
    end
    log(("duel started by %d with %d mages"):format(starter,#ids))
end
local function endMatch()
    if not match then return end
    local ending=match
    for _,id in ipairs(ending.model:ids()) do enterLobby(id) end
    for id in pairs(ending.fx) do removeFx(ending.fx,id) end
    for id,prop in pairs(ending.zoneFx) do Open77.props.remove(prop); ending.zoneFx[id]=nil end
    for id in pairs(ending.wards) do retireWard(ending,id) end
    for id,handle in pairs(ending.travel) do releaseSound(handle or nil); ending.travel[id]=nil end
    match=nil
    log("duel finished: mages returned to the training grounds")
end

-- --- Training dummies ---------------------------------------------------------------------------
-- NPC calls never take the mode down: a refused or failing call is logged (a runtime error in a
-- server script stops the whole resource).
local function npcCall(name,...)
    local fn=Open77.npcs[name] or (Open77.npcs.tasks and Open77.npcs.tasks[name])
    if not fn then return nil,"missing" end
    local ok,result,reason=pcall(fn,...)
    if not ok then log("npc "..name.." failed: "..tostring(result)); return nil,result end
    return result,reason
end
local function spawnDummies()
    local c=C.arena.center
    for index,def in ipairs(C.training.dummies) do
        local id=-index
        local position={x=c.x+def.offset.x,y=c.y+def.offset.y,z=c.z+0.15}
        local npc,reason=npcCall("create",{template=C.training.template,position=position,yaw=180,
            bucket=lobby.bucket,aiMode=Open77.npcs.ai.tasks,damagePolicy=Open77.npcs.damage.immortal,
            behavior={combatEnabled=false,perceptionEnabled=false,voiceEnabled=false},
            streamingRadius=150,despawnWhenUnobserved=false})
        if not npc then log("training dummy "..def.name.." refused: "..tostring(reason)) end
        lobby.model:addDummy(id,def.name,position,C.training.health)
        dummies[id]={npc=npc,def=def}
        if npc and def.patrol then
            local points={}
            for _,p in ipairs(def.patrol) do points[#points+1]={x=c.x+p.x,y=c.y+p.y,z=c.z+0.15,waitMs=600} end
            local ok,why=npcCall("patrol",npc,points,{speed="walk",loop=true,backAndForth=true})
            if not ok then log("training dummy patrol refused: "..tostring(why)) end
        end
    end
end
local function followDummies()
    for id,dummy in pairs(dummies) do
        if dummy.npc and dummy.def.patrol then
            local npc=npcCall("get",dummy.npc)
            if npc and npc.x then lobby.model:moveDummy(id,{x=npc.x,y=npc.y,z=npc.z}) end
        end
    end
end

-- --- Presentation of one instance's events --------------------------------------------------------
local function present(arena,event)
    local model=arena.model
    local spell=event.spell and C.spells[event.spell]
    if event.kind=="phase" then
        if event.phase~="active" then
            for id in pairs(model.members) do if not model.members[id].dummy then Open77.locomotion.stopClip(id,nil,120) end end
            for id in pairs(arena.wards) do retireWard(arena,id) end
        end
        if event.phase=="preparing" then
            arena.started=true
            local ids=model:ids()
            for index,id in ipairs(ids) do
                if model.members[id].ready then
                    local position,heading=spawn(index,#ids); place(id,arena,position,heading,model.epoch)
                end
            end
        elseif event.phase=="finished" or (event.phase=="waiting" and arena.started) then arena.ending=true end
        log(("%s phase=%s round=%d winner=%d"):format(arena.name,event.phase,event.round,event.winner))
    elseif event.kind=="cast" and spell then
        local played,playback=Open77.locomotion.playClip(event.player,event.spell,{blendInMs=60,blendOutMs=120})
        if not played then log("casting animation refused "..tostring(playback)) end
        if not spellSound(arena,event.spell,"cast",event.position) then
            local handle,reason=Play3DSound(spell.audio,event.position,
                {network=true,bucket=arena.bucket,volume=0.65,maxDistance=65,minDistance=3,duration=3})
            if not handle then log("sound refused "..tostring(reason)) end
        end
    elseif event.kind=="projectile" and spell then
        if arena.fx[event.id] then Open77.effects.update(arena.fx[event.id],{position=event.position})
        else arena.fx[event.id]=createFx(spell.effect,event.position,4000,arena.bucket) end
        -- The flight's sound follows the projectile.
        if arena.travel[event.id] then SetSoundPosition(arena.travel[event.id],event.position)
        elseif arena.travel[event.id]==nil then arena.travel[event.id]=spellSound(arena,event.spell,"travel",event.position,{volume=0.7,maxDistance=45}) or false end
    elseif event.kind=="projectile_end" then
        removeFx(arena.fx,event.id)
        releaseSound(arena.travel[event.id] or nil); arena.travel[event.id]=nil
    elseif event.kind=="zone" and spell then
        arena.zoneFx[event.id]=AetherfallScene.sigil(event.position,spell.radius,event.durationMs+500,arena.bucket)
        spellSound(arena,event.spell,"zone",event.position,{volume=0.75,maxDistance=70})
    elseif event.kind=="zone_end" then
        if arena.zoneFx[event.id] then Open77.props.remove(arena.zoneFx[event.id]); arena.zoneFx[event.id]=nil end
    elseif (event.kind=="hit" or event.kind=="impact") and spell then
        Open77.effects.play(spell.impact or "sparks.burst.small",{position=event.position,bucket=arena.bucket,range=100})
        -- A projectile sounds where it hits; an area once, at its eruption (not again per victim).
        if event.kind=="impact" then spellSound(arena,event.spell,"impact",event.position,{volume=1,maxDistance=90})
        elseif spell.kind=="projectile" then spellSound(arena,event.spell,"impact",event.position) end
        if event.kind=="hit" and (event.absorbed or 0)>0 then spellSound(arena,"ward","deflect",event.position,{volume=0.9}) end
    elseif event.kind=="shield" then
        retireWard(arena,event.player)
        arena.wards[event.player]=AetherfallScene.ward(event.player,event.position,event.durationMs,arena.bucket)
    elseif event.kind=="eliminated" then
        retireWard(arena,event.player)
        local victim=model.members[event.player]
        if victim and victim.position then spellSound(arena,"_eliminated","impact",victim.position,{volume=0.9,maxDistance=70}) end
        if event.dummy then
            local dummy=dummies[event.player]
            if dummy and dummy.npc and not npcCall("kill",dummy.npc,"training") then npcCall("setRagdoll",dummy.npc,true) end
        else Open77.locomotion.stopClip(event.player,nil,100) end
    elseif event.kind=="respawned" then
        local dummy=dummies[event.player]
        if dummy and dummy.npc then
            -- The NPC's own health is not the dummy's (the mode keeps that): revive it at its default.
            if not npcCall("revive",dummy.npc) then npcCall("setRagdoll",dummy.npc,false) end
        end
    elseif event.kind=="placement_timeout" then
        notice(event.player,"Arena placement timed out: back to the training grounds.")
    end
    -- Transforms use the native replicated effect channel. HUD sees only semantic events.
    if event.kind~="projectile" and event.kind~="projectile_end" then broadcast(arena,"aetherfall:event",event) end
end

-- What a mage's HUD and Conclave menu show: the instance's state and the duel queue.
local function stateFor(id)
    local member=members[id]; local arena=arenaOf(member)
    local state=arena.model:snapshot(id)
    local names,inQueue={},false
    for _,q in ipairs(lobbyQueue()) do names[#names+1]=Open77.players.name(q); if q==id then inQueue=true end end
    state.arena=member.arena
    state.lobby={queue=names,queued=inQueue,minPlayers=C.duel.minPlayers,
        canStart=match==nil and inQueue and #names>=C.duel.minPlayers,
        duel=match and {phase=match.model.phase,round=match.model.round,players=match.model:players()} or nil}
    return state
end
local function sendState(id) if members[id] then TriggerClientEvent("aetherfall:state",id,stateFor(id)) end end

RegisterCommand("aether",function(id,args)
    id=tonumber(id)
    if not id or id<=0 then
        log(("training players=%d dummies=%d queue=%d duel=%s"):format(lobby.model:players(),#C.training.dummies,#queue,
            match and (match.model.phase.." round "..match.model.round) or "none"))
        return
    end
    local member=members[id]
    if args[1]=="leave" then leave(id)
    elseif args[1]=="queue" and member then if member.arena=="lobby" and not queued(id) then queue[#queue+1]=id end; sendState(id)
    elseif args[1]=="start" and member then startMatch(id)
    elseif args[1]=="status" then
        local arena=arenaOf(member); local p=arena and arena.model.members[id]
        local report=("player=%d arena=%s phase=%s hp=%s mana=%s damage=%s queued=%s"):format(
            id,member and member.arena or "-",arena and arena.model.phase or "-",p and p.hp or "-",
            p and math.floor(p.mana) or "-",p and p.damage or "-",tostring(queued(id)))
        log(report); notice(id,report)
    else join(id) end
end,false)
-- The Conclave menu (client: aetherfall:menu with an action).
RegisterNetEvent("aetherfall:menu",function(action)
    local id=tonumber(source); local member=members[id]
    if not member or type(action)~="string" then return end
    local now=GetGameTimer()
    if now<member.nextMenu then return end
    member.nextMenu=now+250
    if action=="queue" then
        if member.arena~="lobby" then notice(id,"Finish your duel first.")
        elseif not queued(id) then queue[#queue+1]=id; notice(id,"You joined the duel queue.") end
    elseif action=="unqueue" then unqueue(id); notice(id,"You left the duel queue.")
    elseif action=="start" then startMatch(id)
    elseif action=="forfeit" then
        if member.arena=="duel" then notice(id,"You left the duel."); enterLobby(id) end
    elseif action=="reset_dummies" then
        if member.arena=="lobby" then lobby.model:resetDummies(); notice(id,"The dummies stand again.") end
    end
    for other in pairs(members) do sendState(other) end
end)
RegisterNetEvent("aetherfall:cast",function(spell,direction,sequence)
    local id=tonumber(source); local member=members[id]
    if not member then return end
    local now=GetGameTimer()
    if now<member.nextRequest then return end
    member.nextRequest=now+60
    local arena=arenaOf(member)
    local read=Open77.players.get(id)
    if not read or not read.ready or not read.alive or read.bucket~=arena.bucket or read.inVehicle then return end
    if not read.position or not read.ageMs or read.ageMs>C.rules.snapshotAgeMs then return end
    arena.model:position(id,read.position,arena.model.now-read.ageMs)
    local ok,reason=arena.model:cast(id,spell,direction,sequence)
    if not ok then TriggerClientEvent("aetherfall:refused",id,{reason=reason,sequence=sequence}) end
end)
RegisterNetEvent("aetherfall:request",function()
    local id=tonumber(source); local member=members[id]
    if not member then return end
    local now=GetGameTimer()
    if now<(member.nextSnapshotRequest or 0) then return end
    member.nextSnapshotRequest=now+500
    sendState(id)
end)
-- All native attacks are excluded from this mode's rules; mana/HP are the mode's ledger.
Open77.combat.onDamage(function(event)
    if members[tonumber(event.victim)] or members[tonumber(event.attacker)] then return false end
end)
AddEventHandler("onPlayerReady",function(id)
    id=tonumber(id); if id and not members[id] then pendingJoin[id]=GetGameTimer()+30000 end
end)
AddEventHandler("onPlayerDisconnected",function(id) leave(tonumber(id),true) end)
AddEventHandler("onResourceStop",function(name)
    if name~=GetCurrentResourceName() then return end
    stopping=true
    for id in pairs(members) do leave(id) end
end)

local function tickArena(arena)
    for id,member in pairs(members) do
        if arenaOf(member)==arena then
            local read=Open77.players.get(id)
            local p=arena.model.members[id]
            if read and p and read.position and read.ageMs and read.bucket==arena.bucket and read.alive and read.ready then
                arena.model:position(id,read.position,arena.model.now-read.ageMs)
                if not member.wand and GetGameTimer()>=(member.nextWandTry or 0) and read.ageMs<=C.rules.snapshotAgeMs then
                    member.wand=AetherfallScene.wand(id,read.position,arena.bucket)
                    member.nextWandTry=GetGameTimer()+1000
                end
            elseif p then p.position=nil end
            -- The training grounds never freeze anyone; a duel freezes outside its active rounds.
            local frozen=arena~=lobby and p~=nil and (arena.model.phase~="active" or not p.alive or not p.ready)
            if frozen~=member.frozen then
                local ok=Open77.players.setFrozen(id,frozen)
                if ok then member.frozen=frozen end
            end
        end
    end
    arena.model:step(GetGameTimer())
    for _,event in ipairs(arena.model:drain()) do present(arena,event) end
    for id in pairs(arena.wards) do
        local p=arena.model.members[id]
        if not p or not p.alive or p.shield<=0 then retireWard(arena,id,p and p.alive) end
    end
end

CreateThread(function()
    Open77.routingBuckets.setPopulationEnabled(C.bucket,false)
    Open77.routingBuckets.setPopulationEnabled(lobby.bucket,false)
    spawnDummies()
    for _,id in ipairs(Open77.players.all()) do pendingJoin[tonumber(id)]=GetGameTimer()+30000 end
    local function tick()
        for id,deadline in pairs(pendingJoin) do
            if GetGameTimer()>=deadline then pendingJoin[id]=nil
            else join(id,true) end
        end
        -- Members who vanished, or left the instance's bucket once arrived there.
        local removed={}
        for id,member in pairs(members) do
            local read=Open77.players.get(id); local arena=arenaOf(member); local p=arena.model.members[id]
            if not read then removed[#removed+1]=id
            elseif p and p.ready and read.bucket~=arena.bucket then removed[#removed+1]=id
            elseif read.lifePhase and not read.alive then removed[#removed+1]=id end
        end
        for _,id in ipairs(removed) do leave(id) end
        followDummies()
        tickArena(lobby)
        if match then
            tickArena(match)
            -- A duel whose mages never arrived ends too.
            if match.ending or (not match.started and GetGameTimer()-match.createdAt>30000) then endMatch() end
        end
        if GetGameTimer()-lastSnapshot>=C.snapshotMs then
            lastSnapshot=GetGameTimer()
            for id in pairs(members) do sendState(id) end
        end
    end
    -- One failing tick is logged and the arena goes on (an uncaught error stops the whole resource).
    local failures=0
    while not stopping do
        local ok,err=pcall(tick)
        if not ok then
            failures=failures+1
            if failures<=20 or failures%100==0 then log(("tick error #%d: %s"):format(failures,tostring(err))) end
        end
        Wait(C.tickMs)
    end
end)
