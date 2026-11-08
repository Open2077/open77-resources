-- Deterministic rules. No native calls, client hit claims, wall-clock reads or yields.
-- The adapter supplies fresh authoritative positions and consumes presentation events.
AetherfallDuel = {}
local Duel = AetherfallDuel
Duel.__index = Duel
local function finite(n) return type(n)=="number" and n==n and math.abs(n)<math.huge end
local function vector(v)
    return type(v)=="table" and finite(v.x) and finite(v.y) and finite(v.z)
        and math.abs(v.x)<1e6 and math.abs(v.y)<1e6 and math.abs(v.z)<1e6
end
local function copy(v) return {x=v.x,y=v.y,z=v.z} end
local function add(a,b,t) return {x=a.x+b.x*t,y=a.y+b.y*t,z=a.z+b.z*t} end
local function distance2(a,b) return (a.x-b.x)^2+(a.y-b.y)^2+(a.z-b.z)^2 end
local function normalized(v)
    if not vector(v) then return nil end
    local length=math.sqrt(v.x^2+v.y^2+v.z^2)
    if length<0.1 or length>2 then return nil end
    return {x=v.x/length,y=v.y/length,z=v.z/length}
end
-- Earliest contact against the vertical body capsule, including rounded caps.
-- A swept segment prevents fast spells tunnelling between simulation ticks.
local function contact(a,b,feet,radius)
    local d={x=b.x-a.x,y=b.y-a.y,z=b.z-a.z}
    local r=radius+0.42
    local low,high=feet.z+0.42,feet.z+1.42
    local nearest=math.max(low,math.min(high,a.z))
    if (a.x-feet.x)^2+(a.y-feet.y)^2+(a.z-nearest)^2<=r*r then return 0 end
    local best
    local function accept(t)
        if t and t>=0 and t<=1 and (not best or t<best) then best=t end
    end
    local function roots(aa,bb,cc,check)
        if aa<1e-12 then return end
        local discriminant=bb*bb-4*aa*cc
        if discriminant<0 then return end
        local root=math.sqrt(discriminant)
        for _,t in ipairs({(-bb-root)/(2*aa),(-bb+root)/(2*aa)}) do
            if not check or check(t) then accept(t) end
        end
    end
    local x,y=a.x-feet.x,a.y-feet.y
    roots(d.x*d.x+d.y*d.y,2*(x*d.x+y*d.y),x*x+y*y-r*r,
        function(t) local z=a.z+d.z*t; return z>=low and z<=high end)
    for _,z in ipairs({low,high}) do
        local dz=a.z-z
        roots(d.x*d.x+d.y*d.y+d.z*d.z,2*(x*d.x+y*d.y+dz*d.z),x*x+y*y+dz*dz-r*r)
    end
    return best
end
Duel.contact = contact

-- options.practice: the training grounds. No rounds: spells always work, players never harm each
-- other and only training dummies (addDummy) take damage, rising again after config.training.respawnMs.
-- options.finish: a match ends in "finished" after its results instead of starting again.
function Duel.new(config,options)
    options=options or {}
    return setmetatable({config=config,now=0,phase=options.practice and "practice" or "waiting",phaseUntil=0,round=0,epoch=0,
        practice=options.practice==true,finish=options.finish==true,
        members={},projectiles={},zones={},events={},nextId=0,revision=0,winner=0},Duel)
end
function Duel:players()
    local count=0; for _,p in pairs(self.members) do if not p.dummy then count=count+1 end end
    return count
end
-- A training dummy: a member with a negative id, always fresh, never casting.
function Duel:addDummy(id,name,position,health)
    if not self.practice or not finite(id) or id>=0 or self.members[id] or not vector(position) then return false end
    health=health or self.config.rules.health
    self.members[id]={id=id,name=tostring(name or "Dummy"):sub(1,40),dummy=true,ready=true,alive=true,
        hp=health,maxHp=health,mana=0,shield=0,shieldUntil=0,wins=0,kills=0,deaths=0,damage=0,hits=0,
        sequence=0,cooldowns={},castUntil=0,position=copy(position),observedAt=self.now}
    return true
end
function Duel:moveDummy(id,position)
    local p=self.members[id]
    if not p or not p.dummy or not vector(position) then return false end
    p.position=copy(position); p.observedAt=self.now; return true
end
function Duel:resetDummies()
    for _,p in pairs(self.members) do
        if p.dummy then p.hp=p.maxHp; p.respawnAt=nil
            if not p.alive then p.alive=true; self:emit("respawned",{player=p.id,position=copy(p.position)}) end
        end
    end
end
function Duel:emit(kind, data)
    data=data or {}; data.kind=kind; data.at=self.now
    self.events[#self.events+1]=data
end
function Duel:drain() local events=self.events; self.events={}; return events end
function Duel:ids()
    local ids={}; for id in pairs(self.members) do ids[#ids+1]=id end
    table.sort(ids); return ids
end
function Duel:join(id,name)
    if not finite(id) or id<1 or id%1~=0 then return false,"invalid_player" end
    if self.members[id] then return false,"already_joined" end
    if self:players()>=(self.practice and (self.config.lobby and self.config.lobby.maxPlayers or 32) or self.config.maxPlayers) then return false,"arena_full" end
    self.members[id]={id=id,name=tostring(name or ("Mage "..id)):sub(1,40),ready=false,
        hp=self.config.rules.health,maxHp=self.config.rules.health,mana=self.config.rules.mana,shield=0,shieldUntil=0,
        wins=0,kills=0,deaths=0,damage=0,hits=0,sequence=0,cooldowns={},castUntil=0,alive=false}
    self:emit("joined",{player=id}); return true
end
function Duel:leave(id)
    if not self.members[id] then return end
    self.members[id]=nil
    for i=#self.projectiles,1,-1 do
        if self.projectiles[i].owner==id then
            self:emit("projectile_end",{id=self.projectiles[i].id}); table.remove(self.projectiles,i)
        end
    end
    for i=#self.zones,1,-1 do
        if self.zones[i].owner==id then
            self:emit("zone_end",{id=self.zones[i].id}); table.remove(self.zones,i)
        end
    end
    self:emit("left",{player=id})
    self:evaluate()
end
function Duel:setReady(id,ready)
    local p=self.members[id]; if not p then return end
    p.ready=ready==true
    if not p.ready then p.position=nil; p.alive=false
    elseif self.practice then p.alive=true end   -- the training grounds have no rounds to wait for
end
function Duel:placed(id,epoch)
    local p=self.members[id]
    if self.phase~="preparing" or epoch~=self.epoch or not p or not p.ready then return false end
    p.placed=true; return true
end
function Duel:position(id,position,observedAt)
    local p=self.members[id]
    if not p or not vector(position) or not finite(observedAt) or observedAt>self.now then return false end
    p.position=copy(position); p.observedAt=observedAt; return true
end
function Duel:inside(position,margin)
    if not vector(position) then return false end
    local c,a=self.config.arena.center,self.config.arena
    return (position.x-c.x)^2+(position.y-c.y)^2<=(a.radius+(margin or 0))^2
        and math.abs(position.z-c.z)<=a.height
end
function Duel:usable(p)
    return p and p.ready and p.position and p.observedAt and self.now-p.observedAt<=self.config.rules.snapshotAgeMs
end
function Duel:clearCasts()
    for _,p in ipairs(self.projectiles) do self:emit("projectile_end",{id=p.id}) end
    for _,z in ipairs(self.zones) do self:emit("zone_end",{id=z.id}) end
    self.projectiles={}; self.zones={}
end
function Duel:transition(phase,duration)
    self.phase=phase; self.phaseUntil=self.now+(duration or 0); self.epoch=self.epoch+1
    self:emit("phase",{phase=phase,round=self.round,winner=self.winner})
end
function Duel:prepare()
    self:clearCasts(); self.round=self.round+1
    for _,id in ipairs(self:ids()) do
        local p=self.members[id]
        p.hp=self.config.rules.health; p.mana=self.config.rules.mana
        p.alive=p.ready; p.shield=0; p.shieldUntil=0; p.cooldowns={}; p.castUntil=0
        p.placed=false; p.outsideSince=nil
    end
    self:transition("preparing",20000)
end
function Duel:evaluate()
    if self.practice or self.phase=="finished" then return end
    local ready,alive={},{}
    for _,id in ipairs(self:ids()) do
        local p=self.members[id]
        if p.ready then ready[#ready+1]=id end
        if p.ready and p.alive then alive[#alive+1]=id end
    end
    if #ready<2 then
        if self.phase~="waiting" then self:clearCasts(); self:transition("waiting") end
        return
    end
    if self.phase=="waiting" then self:prepare(); return end
    if self.phase=="preparing" then
        local placed=0
        for _,id in ipairs(ready) do if self.members[id].placed then placed=placed+1 end end
        if placed==#ready then self:transition("countdown",self.config.rules.countdownMs)
        elseif self.now>=self.phaseUntil then
            for _,id in ipairs(ready) do
                if not self.members[id].placed then self:setReady(id,false); self:emit("placement_timeout",{player=id}) end
            end
            self:clearCasts(); self:transition("waiting")
        end
        return
    end
    if self.phase=="active" and (#alive<=1 or self.now>=self.phaseUntil) then
        self.winner=#alive==1 and alive[1] or 0
        -- Expiry is a draw; damage dealt never substitutes for a surviving win.
        if self.winner~=0 then self.members[self.winner].wins=self.members[self.winner].wins+1 end
        self:clearCasts()
        local champion=self.winner~=0 and self.members[self.winner].wins>=self.config.rules.wins
        self:transition(champion and "results" or "intermission",
            champion and self.config.rules.resultMs or self.config.rules.intermissionMs)
    end
end
function Duel:cast(id,spellId,direction,sequence)
    local p=self.members[id]; local spell=self.config.spells[spellId]
    if not p or not p.ready then return false,"not_in_arena" end
    if not finite(sequence) or sequence%1~=0 or sequence<=p.sequence or sequence>2147483647 then return false,"stale_cast" end
    p.sequence=sequence -- Every authenticated intent is consumed, including a refused cast.
    if not spell then return false,"unknown_spell" end
    if (self.phase~="active" and not self.practice) or not p.alive or p.dummy then return false,"round_not_active" end
    if not self:usable(p) or (not self.practice and not self:inside(p.position,0.5)) then return false,"position_unavailable" end
    if self.now<(p.cooldowns[spellId] or 0) then return false,"cooldown" end
    if self.now<p.castUntil then return false,"casting" end
    if p.mana<spell.cost then return false,"mana" end
    local aim=normalized(direction)
    if not aim then return false,"invalid_aim" end
    if #self.projectiles+#self.zones>=128 then return false,"cast_capacity" end
    p.mana=p.mana-spell.cost; p.cooldowns[spellId]=self.now+spell.cooldownMs
    p.castUntil=self.now+math.max(self.config.rules.castLockMs,spell.windupMs)
    self.nextId=self.nextId+1
    local origin={x=p.position.x,y=p.position.y,z=p.position.z+1.25}
    local cast={id=self.nextId,owner=id,spell=spellId,position=origin,direction=aim,
        createdAt=self.now,launchAt=self.now+spell.windupMs,travelled=0}
    self:emit("cast",{id=cast.id,player=id,spell=spellId,position=copy(origin),direction=aim})
    if spell.kind=="shield" then
        p.shield=spell.shield; p.shieldUntil=self.now+spell.durationMs
        self:emit("shield",{player=id,position=copy(origin),durationMs=spell.durationMs})
    elseif spell.kind=="projectile" then
        self.projectiles[#self.projectiles+1]=cast
    else
        -- Aim projects onto the arena floor. Horizontal look chooses max range;
        -- looking down chooses a closer mark. Origin is always server-derived.
        local length=spell.range
        if aim.z< -0.05 then length=math.min(length,1.25/-aim.z) end
        cast.position=add(origin,aim,length); cast.position.z=self.config.arena.center.z+0.06
        local c=self.config.arena.center
        local dx,dy=cast.position.x-c.x,cast.position.y-c.y
        local radius=math.sqrt(dx*dx+dy*dy)
        if radius>self.config.arena.radius then
            cast.position.x=c.x+dx/radius*self.config.arena.radius
            cast.position.y=c.y+dy/radius*self.config.arena.radius
        end
        self.zones[#self.zones+1]=cast
        self:emit("zone",{id=cast.id,player=id,spell=spellId,position=copy(cast.position),
            radius=spell.radius,durationMs=spell.windupMs})
    end
    return true,cast.id
end
-- Whether a cast of `owner` can strike member `p`: in practice only dummies are targets
-- (spells pass through other mages).
function Duel:target(p,owner)
    return p.id~=owner and p.alive and self:usable(p) and (not self.practice or p.dummy==true)
end
function Duel:damage(victim,attacker,amount,spell,position)
    local p=self.members[victim]
    if not p or not p.alive or (self.phase~="active" and not self.practice) then return end
    if self.practice and not p.dummy then return end
    local absorbed=math.min(p.shield,amount); p.shield=p.shield-absorbed
    local dealt=math.min(p.hp,amount-absorbed); p.hp=p.hp-dealt
    local caster=self.members[attacker]; if caster then caster.damage=caster.damage+dealt; caster.hits=(caster.hits or 0)+1 end
    self:emit("hit",{player=victim,attacker=attacker,amount=dealt,absorbed=absorbed,
        spell=spell,position=copy(position or p.position),dummy=p.dummy})
    if p.hp<=0 then
        p.alive=false; p.deaths=p.deaths+1
        if caster then caster.kills=caster.kills+1 end
        if p.dummy then p.respawnAt=self.now+(self.config.training and self.config.training.respawnMs or 3000) end
        self:emit("eliminated",{player=victim,attacker=attacker,spell=spell,dummy=p.dummy})
    end
end
function Duel:step(now)
    assert(type(now)=="number" and now>=self.now and now<math.huge,"monotonic time required")
    local previous=self.now; self.now=now
    -- No catch-up burst after a stall: retire travelling casts instead of granting
    -- retroactive hits against bodies whose current snapshots describe another time.
    local hitch=now-previous>250
    local dt=math.min(250,now-previous)/1000
    for _,id in ipairs(self:ids()) do
        local p=self.members[id]
        if p.dummy then
            -- Dummies stand where the adapter last put them; they rise again after their respawn delay.
            p.observedAt=now
            if not p.alive and p.respawnAt and now>=p.respawnAt then
                p.alive=true; p.hp=p.maxHp; p.respawnAt=nil
                self:emit("respawned",{player=id,position=copy(p.position)})
            end
        else p.mana=math.min(self.config.rules.mana,p.mana+self.config.rules.manaRegen*dt) end
        if p.shieldUntil<=now then p.shield=0 end
    end
    if self.phase=="countdown" and now>=self.phaseUntil then
        self:transition("active",self.config.rules.roundMs)
    elseif self.phase=="results" and self.finish and now>=self.phaseUntil then
        self:clearCasts(); self:transition("finished")
    elseif (self.phase=="intermission" or self.phase=="results") and now>=self.phaseUntil then
        if self.phase=="results" then
            for _,p in pairs(self.members) do p.wins=0; p.kills=0; p.deaths=0; p.damage=0 end
            self.round=0; self.winner=0
        end
        self:prepare()
    end
    if self.phase=="active" or self.practice then
        if hitch then self:clearCasts() end
        for i=#self.projectiles,1,-1 do
            local cast=self.projectiles[i]; local spell=self.config.spells[cast.spell]
            if now>=cast.launchAt then
                local seconds=math.max(0,now-math.max(previous,cast.launchAt))/1000
                local length=math.min(spell.speed*seconds,spell.range-cast.travelled)
                local destination=add(cast.position,cast.direction,length)
                local target,first
                for _,id in ipairs(self:ids()) do
                    local p=self.members[id]
                    if self:target(p,cast.owner) then
                        local t=contact(cast.position,destination,p.position,spell.radius)
                        if t and (not first or t<first) then first=t; target=id end
                    end
                end
                cast.travelled=cast.travelled+length
                if target then
                    local hit=add(cast.position,cast.direction,length*first)
                    self:damage(target,cast.owner,spell.damage,cast.spell,hit)
                end
                cast.position=destination
                if target or cast.travelled>=spell.range or (not self.practice and not self:inside(destination,4)) then
                    self:emit("projectile_end",{id=cast.id}); table.remove(self.projectiles,i)
                else self:emit("projectile",{id=cast.id,spell=cast.spell,position=copy(destination)}) end
            end
        end
        for i=#self.zones,1,-1 do
            local zone=self.zones[i]; local spell=self.config.spells[zone.spell]
            if now>=zone.launchAt then
                self:emit("impact",{id=zone.id,spell=zone.spell,position=copy(zone.position),radius=spell.radius})
                for _,id in ipairs(self:ids()) do
                    local p=self.members[id]
                    if self:target(p,zone.owner) and distance2(p.position,zone.position)<=spell.radius^2 then
                        self:damage(id,zone.owner,spell.damage,zone.spell,zone.position)
                    end
                end
                self:emit("zone_end",{id=zone.id}); table.remove(self.zones,i)
            end
        end
        for _,id in ipairs(self:ids()) do
            local p=self.members[id]
            if not self.practice and p.alive and self:usable(p) then
                if self:inside(p.position,1) then p.outsideSince=nil
                else
                    p.outsideSince=p.outsideSince or now
                    if now-p.outsideSince>=2000 then
                        self:damage(id,0,self.config.rules.health+self.config.spells.ward.shield,"boundary",p.position)
                    end
                end
            end
        end
    end
    self:evaluate(); self.revision=self.revision+1
end
function Duel:snapshot(id)
    local roster,dummies={},{}
    for _,key in ipairs(self:ids()) do
        local p=self.members[key]
        if p.dummy then
            dummies[#dummies+1]={id=key,name=p.name,hp=p.hp,maxHp=p.maxHp,alive=p.alive,
                position=p.position and copy(p.position) or nil}
        else
            roster[#roster+1]={id=key,name=p.name,hp=p.hp,maxHp=self.config.rules.health,
                shield=p.shield,wins=p.wins,kills=p.kills,deaths=p.deaths,damage=p.damage,
                alive=p.alive,ready=p.ready,position=p.position and copy(p.position) or nil}
        end
    end
    local p=self.members[id]; local own
    if p and not p.dummy then
        own={id=id,hp=p.hp,maxHp=self.config.rules.health,mana=p.mana,maxMana=self.config.rules.mana,
            alive=p.alive,ready=p.ready,shield=p.shield,sequence=p.sequence,cooldowns={},
            damage=p.damage,hits=p.hits or 0,kills=p.kills,
            shieldMs=math.max(0,p.shieldUntil-self.now),castMs=math.max(0,p.castUntil-self.now),
            outsideMs=p.outsideSince and math.max(0,2000-(self.now-p.outsideSince)) or nil}
        for spell,untilAt in pairs(p.cooldowns) do own.cooldowns[spell]=math.max(0,untilAt-self.now) end
    end
    return {revision=self.revision,phase=self.phase,remainingMs=math.max(0,self.phaseUntil-self.now),
        round=self.round,winner=self.winner,roster=roster,self=own,firstTo=self.config.rules.wins,
        practice=self.practice,dummies=dummies}
end
