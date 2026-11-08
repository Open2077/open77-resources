-- Exercise the real mode, scene and rules together through public API fakes.
-- In particular, the fake registry does NOT expire TTLs: cleanup assertions
-- must be satisfied by the mode's authority lifecycle, not the safety timeout.
local root = ... or "resources/gamemodes/open77_aetherfall/"
local passed=0
local function test(name,fn)
    local ok,err=pcall(fn); assert(ok,name..": "..tostring(err))
    passed=passed+1; print("PASS "..name)
end
-- duel=false: the mages stay on the training grounds (they arrive there).
local function fixture(options)
    options=options or {}
    dofile(root.."shared/config.lua"); dofile(root.."server/duel.lua")
    AetherfallSounds=nil
    local f={now=0,nextId=0,props={},commands={},events={},threads={},states={},players={},notices={},
        npcs={},nextNpc=0,killed={},revived={}}
    for id=1,2 do f.players[id]={id=id,ready=true,alive=true,bucket=0,ageMs=0,
        position={x=0,y=0,z=0}} end
    local function run(co)
        local ok,err=coroutine.resume(co); assert(ok,err)
    end
    function GetGameTimer() return f.now end
    function GetCurrentResourceName() return "open77_aetherfall" end
    function Wait() coroutine.yield() end
    function CreateThread(fn)
        local co=coroutine.create(fn); f.threads[#f.threads+1]=co; run(co)
    end
    function SetTimeout() end
    function RegisterCommand(name,fn) f.commands[name]=fn end
    function RegisterNetEvent(name,fn) f.events[name]=fn end
    function AddEventHandler(name,fn) f.events[name]=fn end
    function TriggerClientEvent(name,id,payload)
        if name=="aetherfall:state" then f.states[id]=payload
        elseif name=="aetherfall:notice" then f.notices[id]=payload.text end
    end
    function Play3DSound() return "sound" end
    local function yes() return true end
    f.outfits={}
    exports={open77_appearance={setTemporaryOutfit=function(_,id,outfit) f.outfits[id]=outfit; return true end,clearTemporaryOutfit=yes}}
    Open77={
        players={get=function(id) return f.players[id] end, all=function() return {} end,
            name=function(id) return "Mage "..id end, setFrozen=yes,
            inBucket=function(bucket)
                local ids={};for id,p in pairs(f.players) do if p.bucket==bucket then ids[#ids+1]=id end end
                return ids
            end,
            teleport=function(id,position,options)
                f.players[id].position=position; f.players[id].bucket=options.bucket
                return {await=function() return {state="near"} end}
            end},
        routingBuckets={setPopulationEnabled=yes,getPlayer=function(id) return f.players[id].bucket end,
            setPlayer=function(id,bucket) f.players[id].bucket=bucket end},
        locomotion={set=yes,reset=yes,stopClip=yes,playClip=yes}, combat={onDamage=yes},
        props={
            create=function(def)
                f.nextId=f.nextId+1;f.props[f.nextId]=def;return f.nextId
            end,
            attach=function(id,binding)
                if f.rejectWard and f.props[id].model:match('/ward$') then return nil,"parent_unavailable" end
                f.props[id].binding=binding;return true
            end,
            remove=function(id) f.props[id]=nil;return true end},
        effects={play=yes,update=yes,remove=yes,create=function() return "effect" end},
        npcs={ai={tasks=1},damage={immortal=2},
            create=function(def) f.nextNpc=f.nextNpc+1; f.npcs[f.nextNpc]=def; return f.nextNpc end,
            get=function(id) local d=f.npcs[id]; return d and {x=d.position.x,y=d.position.y,z=d.position.z} end,
            kill=function(id) f.killed[id]=true; return true end,
            -- As the server does: a health beyond the NPC's maximum (100 by default) throws.
            revive=function(id,health)
                if health and health>100 then error("Specified argument was out of the range of valid values. (Parameter 'health')") end
                f.revived[id]=true; return true
            end,
            setRagdoll=yes, tasks={patrol=function(id,points) f.npcs[id].patrol=points; return 1 end}},
    }
    -- options.robes: open77_hogwarts_wear has registered its robes.
    if options.robes then Open77.clothing={info=function(record) return {record=record} end} end
    dofile(root.."server/scene.lua"); dofile(root.."server/main.lua")
    function f:tick(ms)
        for _=1,math.ceil(ms/50) do
            self.now=self.now+50
            local count=#self.threads
            for i=1,count do if coroutine.status(self.threads[i])~="dead" then run(self.threads[i]) end end
        end
    end
    function f:cast(player,spell,sequence,direction)
        source=player
        self.events["aetherfall:cast"](spell,direction or {x=0,y=player==1 and -1 or 1,z=0},sequence or 1)
        self:tick(50)
    end
    function f:menu(player,action)
        source=player; self.events["aetherfall:menu"](action); self:tick(300)
    end
    function f:wards()
        local values={}
        for id,p in pairs(self.props) do if p.model:match('/ward$') then values[id]=p end end
        return values
    end
    f.commands.aether(1,{"join"}); f.commands.aether(2,{"join"}); f:tick(300)
    assert(f.states[1].phase=="practice" and f.states[1].arena=="lobby")
    if options.duel~=false then
        f:menu(1,"queue"); f:menu(2,"queue"); f:menu(2,"start"); f:tick(5300)
        assert(f.states[1].phase=="active" and f.states[1].arena=="duel")
    end
    return f
end
test("ward uses a durable root binding and a bounded safety lifetime",function()
    local f=fixture(); f:cast(1,"ward")
    local _,ward=next(f:wards()); assert(ward)
    assert(ward.binding.parentType=="player" and ward.binding.parentId==1 and not ward.binding.bone)
    assert(ward.binding.offset.z==1.05 and ward.ttlMs==Aetherfall.spells.ward.durationMs)
    assert(ward.collision==false and ward.physics=="none" and ward.bucket==Aetherfall.bucket)
    f.players[1].position={x=2574,y=123,z=96};f:tick(200)
    assert(next(f:wards()) and f.states[1].self.shield==65)
end)
test("ward visual retires at authoritative expiry without registry TTL help",function()
    local f=fixture();f:cast(1,"ward");f:tick(2150)
    assert(not next(f:wards()) and f.states[1].self.shield==0)
end)
test("shield depletion removes the shell while the wearer survives",function()
    local f=fixture();f:cast(2,"ward");f:cast(1,"lance")
    f:tick(400);f:cast(1,"bolt",2);f:tick(1200)
    assert(f.states[2].self.alive and f.states[2].self.hp==195)
    assert(f.states[2].self.shield==0 and not next(f:wards()))
end)
test("leaving ends the duel and returns the other mage to the training grounds",function()
    local f=fixture();f:cast(1,"ward");f:cast(2,"ward")
    local count=0;for _ in pairs(f:wards()) do count=count+1 end;assert(count==2)
    f.commands.aether(1,{"leave"});f:tick(200)
    assert(not next(f:wards()) and f.states[2].phase=="practice" and f.states[2].arena=="lobby")
    assert(f.players[2].bucket==Aetherfall.lobby.bucket)
end)
test("resource stop releases both ward props",function()
    local f=fixture();f:cast(1,"ward");f:cast(2,"ward")
    f.events.onResourceStop("open77_aetherfall")
    assert(not next(f.props))
end)
test("failed visual attachment leaves no orphan and preserves shield authority",function()
    local f=fixture();f.rejectWard=true;f:cast(1,"ward");f:tick(100)
    assert(not next(f:wards()) and f.states[1].self.shield==65)
end)
test("mages arrive on the training grounds, in its own bucket, with passive dummies",function()
    local f=fixture({duel=false})
    assert(f.players[1].bucket==Aetherfall.lobby.bucket and f.players[1].bucket~=Aetherfall.bucket)
    assert(#f.states[1].dummies==#Aetherfall.training.dummies and #f.states[1].roster==2)
    local patrols=0
    for _,npc in pairs(f.npcs) do
        assert(npc.bucket==Aetherfall.lobby.bucket and npc.behavior.combatEnabled==false and npc.behavior.voiceEnabled==false)
        if npc.patrol then patrols=patrols+1 end
    end
    assert(f.nextNpc==#Aetherfall.training.dummies and patrols==1)
end)
test("a spell on the training grounds strikes a dummy, which falls then rises",function()
    local f=fixture({duel=false})
    local p=f.players[1].position; local c=Aetherfall.arena.center
    local dx,dy=c.x-p.x,(c.y+8)-p.y; local len=math.sqrt(dx*dx+dy*dy)
    local aim={x=dx/len,y=dy/len,z=0}
    local function sentinel()
        for _,d in ipairs(f.states[1].dummies) do if d.name=="Sentinel I" then return d end end
    end
    f:cast(1,"lance",1,aim); f:tick(1000)
    assert(sentinel().hp==152 and f.states[1].self.hits==1 and f.states[1].self.damage==48)
    for sequence=2,12 do f:cast(1,"bolt",sequence,aim); f:tick(700); if f.killed[1] then break end end
    -- Sentinel I is the first dummy created: NPC 1.
    assert(f.killed[1] and not sentinel().alive)
    f:tick(Aetherfall.training.respawnMs+200)
    assert(f.revived[1] and sentinel().alive and sentinel().hp==200)
end)
test("a duel needs enough mages in the queue",function()
    local f=fixture({duel=false})
    f:menu(1,"start"); assert(f.states[1].arena=="lobby" and f.notices[1]:match("queue"))
    f:menu(1,"queue"); f:menu(1,"start"); f:tick(500)
    assert(f.states[1].arena=="lobby" and f.states[1].lobby.queued and not f.states[1].lobby.canStart)
    f:menu(2,"queue"); assert(f.states[1].lobby.canStart and #f.states[1].lobby.queue==2)
    f:menu(2,"unqueue"); assert(not f.states[1].lobby.canStart)
end)
test("leaving the duel from the menu returns everyone once it cannot go on",function()
    local f=fixture(); f:menu(1,"forfeit"); f:tick(200)
    assert(f.states[1].arena=="lobby" and f.states[2].arena=="lobby")
    assert(f.players[1].bucket==Aetherfall.lobby.bucket and f.players[2].bucket==Aetherfall.lobby.bucket)
    -- The training grounds keep working afterwards, and a new duel can start.
    f:menu(1,"queue"); f:menu(2,"queue"); f:menu(1,"start"); f:tick(5300)
    assert(f.states[1].phase=="active")
end)
test("mages wear a house robe over the costume once the Hogwarts robes are registered",function()
    local plain=fixture({duel=false})
    assert(plain.outfits[1].OuterChest==Aetherfall.costumes[1].OuterChest)
    local f=fixture({duel=false,robes=true})
    assert(f.outfits[1].OuterChest==Aetherfall.robes[1] and f.outfits[2].OuterChest==Aetherfall.robes[2])
    assert(f.outfits[1].InnerChest==Aetherfall.costumes[1].InnerChest and Aetherfall.costumes[1].OuterChest~=Aetherfall.robes[1])
end)
print(("%d Aetherfall presentation checks passed"):format(passed))
