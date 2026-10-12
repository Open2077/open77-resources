-- Open77 PolyZone: equivalent zone operations, native Open77 resource ownership.
-- MIT; mathematical conventions originate in mkafrin/PolyZone 2.6.2.
local G = assert(require('@polyzone/geometry'))
local P = {version='2.6.2-open77.1'}
local Poly,Box,Circle,Entity,Combo = {},{},{},{},{}
P.PolyZone,P.BoxZone,P.CircleZone,P.EntityZone,P.ComboZone = Poly,Box,Circle,Entity,Combo
local zones, watches, nextId, running = {},{},0,false
local startScheduler
local function now() return Open77.time.monotonic()*1000 end
local function warn(message) print('[polyzone] '..tostring(message)) end
local function invalidate(zone)
    zone._revision=(zone._revision or 0)+1
    for parent in pairs(zone._parents or {}) do parent._gridDirty=true; invalidate(parent) end
end
local function attachMethods(object,class)
    for k,v in pairs(Poly) do if type(v)=='function' then object[k]=v end end
    if class==Entity then for k,v in pairs(Box) do if type(v)=='function' then object[k]=v end end end
    for k,v in pairs(class) do if type(v)=='function' then object[k]=v end end
    return object
end
local function insideZ(zone,p) return (not zone.minZ or p.z>=zone.minZ) and (not zone.maxZ or p.z<=zone.maxZ) end
local function zBounds(options)
    assert(options.minZ==nil or G.finite(options.minZ),'polyzone: invalid minZ')
    assert(options.maxZ==nil or G.finite(options.maxZ),'polyzone: invalid maxZ')
    assert(not options.minZ or not options.maxZ or options.minZ<=options.maxZ,'polyzone: minZ exceeds maxZ')
end
local function safeCall(callback,...)
    local ok,err=pcall(callback,...)
    if not ok then warn('callback failed: '..tostring(err)) end
    return ok
end
local function addWatch(zone,getPoint,callback,interval,exhaustive,damage)
    assert(type(callback)=='function' and type(getPoint)=='function','polyzone: callbacks must be functions')
    interval=interval==nil and 500 or interval
    assert(G.finite(interval) and interval>=0,'polyzone: invalid polling interval')
    local item={zone=zone,getPoint=getPoint,callback=callback,interval=interval,due=0,exhaustive=exhaustive,damage=damage,
        previous=zone.isComboZone and nil or false,insideZones={}}
    -- `and nil or false` is false in Lua: ComboZone intentionally reports its first outside sample.
    if zone.isComboZone then item.previous=nil end
    watches[#watches+1]=item
    startScheduler()
    return function() item.cancelled=true end -- Open77 extension, optional cancellation.
end
local function difference(a,b)
    local out
    for _,v in ipairs(a) do
        local found=false; for _,other in ipairs(b) do if v==other then found=true; break end end
        if not found then out=out or {}; out[#out+1]=v end
    end
    return out
end
local function poll(item)
    local zone=item.zone
    local ok,value=pcall(item.getPoint)
    if not ok then error(value,0) end
    if item.damage then
        if not value then item.health=nil; return end
        if item.health and value.health<item.health then
            safeCall(item.callback,value.health<=0,value.attacker,value.weapon,value.isMelee,value)
        end
        item.health=value.health; return
    end
    -- No incarnation/streamed entity is not a point at (0,0,0). Emit a single
    -- exit on loss and resume normally after respawn/world entry.
    local inside,hit=false,nil
    if value then inside,hit=zone:isPointInside(value) end
    if item.exhaustive then
        local current={}
        if value then inside,current=zone:isPointInsideExhaustive(value) end
        local entered,left=difference(current,item.insideZones),difference(item.insideZones,current)
        if item.previous~=inside or entered or left then
            item.previous,item.insideZones=inside,G.copy(current)
            safeCall(item.callback,inside,value,current,entered,left)
        end
    elseif inside~=item.previous then
        local last=item.hit
        item.previous,item.hit=inside,hit
        if zone.isComboZone then safeCall(item.callback,inside,value,hit or last)
        else safeCall(item.callback,inside,value) end
    end
end
startScheduler=function()
    if running then return end
    running=true
    CreateThread(function()
        local nextDebug=0
        while running do
            local stamp=now()
            local nextPoll=stamp+100
            local count=#watches
            for i=1,count do
                local item=watches[i]
                if item and not item.cancelled and not item.zone.destroyed and not item.zone.paused and stamp>=item.due then
                    item.due=stamp+item.interval
                    local ok,err=pcall(poll,item)
                    if not ok then item.cancelled=true; warn('watch stopped: '..tostring(err)) end
                end
                if item and not item.cancelled and not item.zone.paused then nextPoll=math.min(nextPoll,item.due) end
            end
            for i=#watches,1,-1 do
                if watches[i].cancelled or watches[i].zone.destroyed then table.remove(watches,i) end
            end
            local hasDebug=false
            for _,zone in pairs(zones) do if zone.debugPoly or zone.debugGrid then hasDebug=true; break end end
            if hasDebug and stamp>=nextDebug then
                nextDebug=stamp+100
                for _,zone in pairs(zones) do
                    if zone.debugPoly or zone.debugGrid then
                        local ok,err=pcall(zone.draw,zone,false)
                        if not ok and not zone._drawError then zone._drawError=true; warn(err) end
                    end
                end
            end
            if #watches==0 and not hasDebug then running=false; return end
            if hasDebug then nextPoll=math.min(nextPoll,nextDebug) end
            Wait(math.max(0,math.floor(nextPoll-now())))
        end
    end)
end
local function base(class,flag,options)
    options=options or {}; zBounds(options)
    nextId=nextId+1
    local zone=attachMethods({name=tostring(options.name),data=options.data or {},destroyed=false,paused=false,
        minZ=options.minZ,maxZ=options.maxZ,debugPoly=options.debugPoly==true,debugGrid=options.debugGrid==true,
        debugColors=G.copy(options.debugColors),debugColor=options.debugColor or {0,255,0},
        _key='polyzone:'..nextId,_parents={},_revision=0,_events={},_blips={},_options=G.copy(options)},class)
    zone[flag]=true
    zone._id=nextId
    return zone
end
local function track(zone)
    zones[zone._id]=zone
    if zone.debugPoly or zone.debugGrid then startScheduler() end
    return zone
end
local function finish(zone,options)
    if options and options.debugBlip then zone:addDebugBlip() end
    return zone
end
function Poly:new(points,options)
    options=options or {}
    assert(type(points)=='table' and #points>=3 and #points<=2048,'polyzone: polygon needs 3..2048 points')
    local zone=base(Poly,'isPolyZone',options)
    zone.points={}; for i,p in ipairs(points) do zone.points[i]=G.vector(p) end
    zone.min,zone.max,zone.size,zone.center,zone.area=G.bounds(zone.points)
    assert(zone.area>0 and zone.size.x>0 and zone.size.y>0,'polyzone: degenerate polygon')
    zone.boundingRadius=math.sqrt(zone.size.x^2+zone.size.y^2)/2
    zone.useGrid=options.useGrid~=false; zone.lazyGrid=options.lazyGrid~=false and not zone.debugGrid
    zone.gridDivisions=options.gridDivisions or 30
    assert(math.type(zone.gridDivisions)=='integer' and zone.gridDivisions>=1 and zone.gridDivisions<=256,'polyzone: gridDivisions must be 1..256')
    zone.gridCellWidth,zone.gridCellHeight=zone.size.x/zone.gridDivisions,zone.size.y/zone.gridDivisions
    zone.grid={}; zone.gridArea=0; zone.gridCoverage=0
    if zone.useGrid and not zone.lazyGrid then
        CreateThread(function()
            for y=0,zone.gridDivisions-1 do
                if zone.destroyed then return end
                zone.grid[y]=zone.grid[y] or {}
                for x=0,zone.gridDivisions-1 do
                    local contained=G.insideCell(zone,x,y); zone.grid[y][x]=contained
                    if contained then zone.gridArea=zone.gridArea+zone.gridCellWidth*zone.gridCellHeight end
                    -- Yield within large rows too; grid construction is never
                    -- allowed to monopolise a resource's frame budget.
                    if x % 4==3 then Wait(0); if zone.destroyed then return end end
                end
                Wait(0)
            end
            zone.gridCoverage=zone.gridArea/zone.area
        end)
    end
    return track(zone)
end
function Poly:Create(points,options) return finish(Poly:new(points,options),options) end
function Poly:isPointInside(point)
    if self.destroyed or not point then return false end
    local p=G.vector(point)
    if p.x<self.min.x or p.x>self.max.x or p.y<self.min.y or p.y>self.max.y or not insideZ(self,p) then return false end
    if self.useGrid then
        local x=math.min(self.gridDivisions-1,math.floor((p.x-self.min.x)/self.gridCellWidth))
        local y=math.min(self.gridDivisions-1,math.floor((p.y-self.min.y)/self.gridCellHeight))
        self.grid[y]=self.grid[y] or {}
        if self.grid[y][x]==nil and self.lazyGrid then self.grid[y][x]=G.insideCell(self,x,y) end
        if self.grid[y][x] then return true end
    end
    return G.winding(p,self.points)
end
function Poly:TransformPoint(point) return point end
function Poly:getBoundingBoxMin() return self.min end
function Poly:getBoundingBoxMax() return self.max end
function Poly:getBoundingBoxSize() return self.size end
function Poly:getBoundingBoxCenter() return self.center end
function Poly:getCenter() return self.center end
function Poly:setPaused(paused) self.paused=paused==true end
function Poly:isPaused() return self.paused end
function Poly.getPlayerPosition()
    local s=Open77.character.state()
    return s and s.attached and s.position or nil
end
function Poly.getPlayerHeadPosition()
    local s,err=Open77.world.entityGeometry(0)
    return s and s.head or nil,err
end
function Poly.rotate(origin,point,theta) return G.rotate(origin,point,theta) end
function Poly:onPointInOut(getPoint,callback,waitInMS) return addWatch(self,getPoint,callback,waitInMS) end
function Poly:onPlayerInOut(callback,waitInMS) return self:onPointInOut(Poly.getPlayerPosition,callback,waitInMS) end
function Poly:addEvent(eventName)
    assert(type(eventName)=='string' and #eventName>0 and #eventName<=100,'polyzone: invalid event name')
    self:removeEvent(eventName)
    self._events[eventName]=assert(RegisterNetEvent('__PolyZone__:'..eventName,function(...)
        if not self.destroyed and self:isPointInside(Poly.getPlayerPosition()) then TriggerEvent(eventName,...) end
    end))
end
function Poly:removeEvent(eventName)
    if self._events[eventName] then RemoveEventHandler(self._events[eventName]); self._events[eventName]=nil end
end
function Poly:addDebugBlip()
    if self.destroyed then return nil,'destroyed' end
    if self.debugBlip then return self.debugBlip end
    local center=self:getCenter()
    if not center then return nil,'entity_not_streamed' end
    local id,err=Open77.blips.create({position=G.vector(center),label=self.name,visible=true})
    if id then self._blips[#self._blips+1]=id; self.debugBlip=id else warn('debug blip: '..tostring(err)) end
    return id,err
end
function Poly:destroy()
    if self.destroyed then return end
    self.destroyed=true; zones[self._id]=nil
    for name in pairs(self._events) do self:removeEvent(name) end
    for _,id in ipairs(self._blips) do Open77.blips.remove(id) end
    self._blips={}
    if Open77.debugDraw then Open77.debugDraw.clear(self._key) end
    invalidate(self)
end
function Box.calculateMinAndMaxZ(minZ,maxZ,scaleZ,offsetZ)
    local a,b=(scaleZ or {})[1] or 1,(scaleZ or {})[2] or 1
    if minZ and maxZ then
        local center,half=(minZ+maxZ)/2,(maxZ-minZ)/2
        minZ,maxZ=center-half*a,center+half*b
    end
    return minZ and minZ-((offsetZ or {})[1] or 0),maxZ and maxZ+((offsetZ or {})[2] or 0)
end
local function rebuildBox(zone)
    local s,o=zone._scale,zone._offset
    local min={x=-zone.width/2*s[3]-o[3],y=-zone.length/2*s[2]-o[2]}
    local max={x=zone.width/2*s[4]+o[4],y=zone.length/2*s[1]+o[1]}
    assert(min.x<max.x and min.y<max.y,'polyzone: scale/offset inverted box')
    zone.min={x=zone.center.x+min.x,y=zone.center.y+min.y}
    zone.max={x=zone.center.x+max.x,y=zone.center.y+max.y}
    zone.size={x=max.x-min.x,y=max.y-min.y}; zone.area=zone.size.x*zone.size.y
    zone.startPos=G.copy(zone.center); zone.offsetPos={x=0,y=0}
    zone.points={{x=zone.min.x,y=zone.min.y},{x=zone.max.x,y=zone.min.y},{x=zone.max.x,y=zone.max.y},{x=zone.min.x,y=zone.max.y}}
    zone.boundingRadius=math.sqrt(math.max(min.x^2,max.x^2)+math.max(min.y^2,max.y^2))
    invalidate(zone)
end
function Box:new(center,length,width,options)
    options=options or {}
    G.positive(length,'length'); G.positive(width,'width')
    local zone=base(Box,'isBoxZone',options)
    zone.isPolyZone=true
    zone.center=G.vector(center); zone.length,zone.width=length,width
    zone._scale,zone._offset=G.scaleOffset(options)
    zone.scaleZ,zone.offsetZ={zone._scale[6],zone._scale[5]},{zone._offset[6],zone._offset[5]}
    zone.minZ,zone.maxZ=Box.calculateMinAndMaxZ(zone.minZ,zone.maxZ,zone.scaleZ,zone.offsetZ)
    zone.offsetRot=options.heading or 0; assert(G.finite(zone.offsetRot),'polyzone: invalid heading')
    zone.useGrid=false; rebuildBox(zone)
    return track(zone)
end
function Box:Create(center,length,width,options) return finish(Box:new(center,length,width,options),options) end
function Box:TransformPoint(point) return G.rotate(self.center,point,self.offsetRot) end
function Box:isPointInside(point)
    if self.destroyed or not point then return false end
    local p=G.vector(point)
    if not insideZ(self,p) then return false end
    p=G.rotate(self.center,p,-self.offsetRot)
    return p.x>=self.min.x and p.x<=self.max.x and p.y>=self.min.y and p.y<=self.max.y
end
function Box:getHeading() return self.offsetRot end
function Box:setHeading(v) if v==nil then return end; assert(G.finite(v),'polyzone: invalid heading'); self.offsetRot=v; invalidate(self) end
function Box:setCenter(v) if not v then return end; self.center=G.vector(v); rebuildBox(self) end
function Box:getLength() return self.length end
function Box:setLength(v) if not v then return end; self.length=G.positive(v,'length'); rebuildBox(self) end
function Box:getWidth() return self.width end
function Box:setWidth(v) if not v then return end; self.width=G.positive(v,'width'); rebuildBox(self) end
function Circle:new(center,radius,options)
    options=options or {}; G.positive(radius,'radius')
    local zone=base(Circle,'isCircleZone',options)
    zone.center,zone.radius,zone.diameter=G.vector(center),radius,radius*2
    zone.useZ=options.useZ==true
    return track(zone)
end
function Circle:Create(center,radius,options) return finish(Circle:new(center,radius,options),options) end
function Circle:isPointInside(point)
    return not self.destroyed and point~=nil and G.distance2(G.vector(point),self.center,self.useZ)<self.radius^2
end
function Circle:getRadius() return self.radius end
function Circle:setRadius(v) if not v then return end; self.radius=G.positive(v,'radius'); self.diameter=v*2; invalidate(self) end
function Circle:setCenter(v) if not v then return end; self.center=G.vector(v); invalidate(self) end
-- Entity handles are generation-checked Open77 handles, never raw engine pointers.
-- A typed reference {kind='vehicle'|'npc'|'player',id=...} survives stream-out/in.
local function refreshEntity(zone)
    local state,err=Open77.world.entityGeometry(zone.entity)
    if not state or not state.attached then zone._streamed=false; zone.error=err or 'entity_not_attached'; return false end
    local dimensions=zone._options.dimensions or state.bounds
    if not dimensions then zone._streamed=false; zone.error='entity_bounds_unavailable'; return false end
    local min,max=G.vector(dimensions.min or dimensions[1]),G.vector(dimensions.max or dimensions[2])
    if min.x>=max.x or min.y>=max.y or min.z>max.z then zone._streamed=false; zone.error='invalid_entity_bounds'; return false end
    zone.dimensions={min,max}; zone._geometry=state
    zone.center=G.vector(state.position); zone.length,zone.width=max.y-min.y,max.x-min.x
    -- GTA boxes were centred at the origin. Open77 model origins are not
    -- guaranteed centred: honour the actual local bounds, including their offset.
    local localCenter={x=(min.x+max.x)/2,y=(min.y+max.y)/2,z=0}
    zone._localCenter=localCenter
    zone.offsetRot=state.heading or math.deg(math.atan(-(state.forward.x),state.forward.y))
    zone.center=G.transform(localCenter,state.position,state.orientation)
    rebuildBox(zone)
    if zone.useZ then
        local minZ,maxZ=math.huge,-math.huge
        for _,x in ipairs({min.x,max.x}) do for _,y in ipairs({min.y,max.y}) do for _,z in ipairs({min.z,max.z}) do
            local world=G.transform({x=x,y=y,z=z},state.position,state.orientation)
            minZ,maxZ=math.min(minZ,world.z),math.max(maxZ,world.z)
        end end end
        zone.minZ,zone.maxZ=Box.calculateMinAndMaxZ(minZ,maxZ,zone.scaleZ,zone.offsetZ)
    else zone.minZ,zone.maxZ=nil,nil end
    zone._streamed,zone.error=true,nil
    for _,id in ipairs(zone._blips) do Open77.blips.update(id,{position=zone.center}) end
    return true
end
function Entity:new(entity,options)
    options=options or {}
    assert(type(entity)=='number' or type(entity)=='table','polyzone: expected Open77 entity handle or typed reference')
    if type(entity)=='table' then
        assert((entity.kind=='entity' or entity.kind=='player' or entity.kind=='vehicle' or entity.kind=='npc')
            and math.type(entity.id)=='integer' and entity.id>=0,'polyzone: invalid typed entity reference')
    else assert(math.type(entity)=='integer' and entity>=0,'polyzone: invalid entity handle') end
    if options.dimensions then
        local min,max=G.vector(options.dimensions.min or options.dimensions[1]),G.vector(options.dimensions.max or options.dimensions[2])
        assert(min.x<max.x and min.y<max.y and min.z<=max.z,'polyzone: invalid entity dimensions')
    end
    local zone=Box:new({x=0,y=0,z=0},1,1,options)
    attachMethods(zone,Entity); zone.isEntityZone=true
    zone.entity,zone.useZ=entity,options.useZ==true
    local ok,err=pcall(refreshEntity,zone)
    if not ok then zone:destroy(); error(err) end
    return zone
end
function Entity:Create(entity,options) return finish(Entity:new(entity,options),options) end
function Entity:isPointInside(point) return not self.destroyed and refreshEntity(self) and Box.isPointInside(self,point) end
function Entity:getCenter() if not self.destroyed then refreshEntity(self) end; return self._streamed and self.center or nil end
function Entity:onEntityDamaged(callback)
    return addWatch(self,function()
        if not refreshEntity(self) then return nil end
        return self._geometry.damage
    end,callback,50,false,true)
end
local function intersectsTree(root,wanted,seen)
    if root==wanted then return true end
    seen=seen or {}; if seen[root] then return false end; seen[root]=true
    for _,child in ipairs(root.zones or {}) do if intersectsTree(child,wanted,seen) then return true end end
    return false
end
local function buildComboGrid(combo)
    combo.grid,combo._dynamic={},{}
    for _,zone in ipairs(combo.zones) do
        if not zone.destroyed then
            local radius=zone.radius or zone.boundingRadius
            if zone.isEntityZone or zone.isComboZone or not radius then combo._dynamic[#combo._dynamic+1]=zone
            else
                local minX,maxX=math.floor((zone.center.x-radius)/256),math.floor((zone.center.x+radius)/256)
                local minY,maxY=math.floor((zone.center.y-radius)/256),math.floor((zone.center.y+radius)/256)
                if (maxX-minX+1)*(maxY-minY+1)>4096 then combo._dynamic[#combo._dynamic+1]=zone
                else for y=minY,maxY do for x=minX,maxX do
                    local key=x..':'..y; combo.grid[key]=combo.grid[key] or {}; combo.grid[key][zone]=true
                end end end
            end
        end
    end
    combo._gridDirty=false
end
function Combo:new(children,options)
    assert(type(children)=='table','polyzone: expected zone array')
    for _,child in ipairs(children) do
        assert(type(child)=='table' and type(child.isPointInside)=='function' and not child.destroyed and child._parents,'polyzone: invalid child zone')
    end
    local zone=base(Combo,'isComboZone',options or {})
    zone.zones={}; zone.useGrid=not options or options.useGrid~=false
    for _,child in ipairs(children) do zone:AddZone(child) end
    return track(zone)
end
function Combo:Create(children,options) return finish(Combo:new(children,options),options) end
function Combo:AddZone(zone)
    assert(type(zone)=='table' and type(zone.isPointInside)=='function' and not zone.destroyed,'polyzone: invalid child zone')
    assert(not intersectsTree(zone,self),'polyzone: cyclic ComboZone')
    for _,child in ipairs(self.zones) do if child==zone then return end end
    self.zones[#self.zones+1]=zone; zone._parents[self]=true; self._gridDirty=true; invalidate(self)
    if self.debugBlip then zone:addDebugBlip() end
end
function Combo:RemoveZone(nameOrFunction)
    local predicate=type(nameOrFunction)=='string' and function(z) return z.name==nameOrFunction end or nameOrFunction
    if type(predicate)~='function' then return nil end
    for i,zone in ipairs(self.zones) do if predicate(zone) then
        table.remove(self.zones,i); zone._parents[self]=nil; self._gridDirty=true; invalidate(self); return zone
    end end
end
function Combo:getZones(point)
    if not self.useGrid then return self.zones end
    point=G.vector(point)
    if self._gridDirty then buildComboGrid(self) end
    local key=math.floor(point.x/256)..':'..math.floor(point.y/256)
    local selected=self.grid[key] or {}; local dynamic={}
    for _,z in ipairs(self._dynamic) do dynamic[z]=true end
    local result={}
    -- Preserve insertion priority regardless of the broadphase path.
    for _,z in ipairs(self.zones) do if selected[z] or dynamic[z] then result[#result+1]=z end end
    return #result>0 and result or nil
end
function Combo:isPointInside(point,zoneName)
    if self.destroyed or not point then return false,nil end
    for _,zone in ipairs(self:getZones(point) or {}) do
        if (zoneName==nil or zone.name==zoneName) and zone:isPointInside(point) then return true,zone end
    end
    return false,nil
end
function Combo:isPointInsideExhaustive(point,out)
    out=out or {}; for i=#out,1,-1 do out[i]=nil end
    if self.destroyed or not point then return false,out end
    for _,zone in ipairs(self:getZones(point) or {}) do if zone:isPointInside(point) then out[#out+1]=zone end end
    return #out>0,out
end
function Combo:onPointInOut(getPoint,callback,interval) return addWatch(self,getPoint,callback,interval) end
function Combo:onPointInOutExhaustive(getPoint,callback,interval) return addWatch(self,getPoint,callback,interval,true) end
function Combo:onPlayerInOutExhaustive(callback,interval) return self:onPointInOutExhaustive(Poly.getPlayerPosition,callback,interval) end
function Combo:addEvent(eventName,zoneName)
    assert(type(eventName)=='string' and #eventName>0 and #eventName<=100,'polyzone: invalid event name')
    self:removeEvent(eventName)
    self._events[eventName]=assert(RegisterNetEvent('__PolyZone__:'..eventName,function(...)
        if not self.destroyed and self:isPointInside(Poly.getPlayerPosition(),zoneName) then TriggerEvent(eventName,...) end
    end))
end
function Combo:addDebugBlip()
    self.debugBlip=true; for _,zone in ipairs(self.zones) do zone:addDebugBlip() end
end
function Combo:destroy()
    if self.destroyed then return end
    Poly.destroy(self)
    for _,zone in ipairs(self.zones) do zone._parents[self]=nil; zone:destroy() end
end
function Combo:printInfo()
    local counts={PolyZone=0,BoxZone=0,CircleZone=0,EntityZone=0,ComboZone=0}
    for _,zone in ipairs(self.zones) do
        local kind=zone.isEntityZone and 'EntityZone' or zone.isBoxZone and 'BoxZone' or zone.isCircleZone and 'CircleZone' or zone.isComboZone and 'ComboZone' or 'PolyZone'
        counts[kind]=counts[kind]+1
    end
    warn(('ComboZone %s: %d zones'):format(self.name,#self.zones))
    for kind,count in pairs(counts) do if count>0 then warn(kind..': '..count) end end
    return counts
end
function Poly.ensureMetatable(zone)
    -- Open77 does not expose Lua metatable mutation. Rehydrate the methods of
    -- a plain serialized zone; callbacks/VM ownership are never serialized.
    assert(type(zone)=='table','polyzone: expected zone')
    if zone._id and zones[zone._id]==zone then return zone end
    local seen={}
    local function rehydrate(value)
        assert(type(value)=='table' and not seen[value],'polyzone: cyclic or invalid serialized zone')
        if value._id and zones[value._id]==value then return value end
        seen[value]=true
        local options=G.copy(value._options or value)
        options.name=value.name; options.data=value.data
        options.debugPoly=false; options.debugGrid=false; options.debugBlip=false
        local fresh
        if value.isComboZone then
            local children={}; for _,child in ipairs(value.zones or {}) do children[#children+1]=rehydrate(child) end
            fresh=Combo:new(children,options)
        elseif value.isEntityZone then fresh=Entity:new(value.entity,options)
        elseif value.isBoxZone then options.heading=value.offsetRot or options.heading; fresh=Box:new(value.center,value.length,value.width,options)
        elseif value.isCircleZone then options.useZ=value.useZ; fresh=Circle:new(value.center,value.radius,options)
        else fresh=Poly:new(value.points,options) end
        for key in pairs(value) do value[key]=nil end
        for key,v in pairs(fresh) do value[key]=v end
        zones[value._id]=value
        for _,child in ipairs(value.zones or {}) do child._parents[fresh]=nil; child._parents[value]=true end
        seen[value]=nil
        return value
    end
    return rehydrate(zone)
end
-- Debug geometry and serialization are kept separate from containment.
local debugGeometry=assert(require('@polyzone/debug'))
function Poly:draw(forceDraw)
    if self.destroyed or not (forceDraw or self.debugPoly or self.debugGrid) then return false end
    if self.isEntityZone and not refreshEntity(self) then
        Open77.debugDraw.clear(self._key); return false
    end
    local spec=debugGeometry.build(self,Poly.getPlayerPosition())
    local ok,err=Open77.debugDraw.set(self._key,spec)
    if not ok and not self._drawError then self._drawError=true; warn('debug drawing: '..tostring(err)) end
    return ok,err
end
function Poly.drawPoly(zone,forceDraw) return Poly.draw(zone,forceDraw) end
function Combo:draw(forceDraw)
    for _,zone in ipairs(self.zones) do if not zone.destroyed then zone:draw(forceDraw or self.debugPoly) end end
end
function P.installGlobals()
    PolyZone,BoxZone,CircleZone,EntityZone,ComboZone=Poly,Box,Circle,Entity,Combo
    return P
end
P.serialize=assert(require('@polyzone/serialize'))
function P.list() local result={}; for _,z in pairs(zones) do result[#result+1]=z end; return result end
function P.destroyAll() local all=P.list(); for _,z in ipairs(all) do z:destroy() end end
AddEventHandler('polyzone:pzcomboinfo',function() for _,z in pairs(zones) do if z.isComboZone then z:printInfo() end end end)
AddEventHandler('onClientResourceStop',function(name)
    if name==GetCurrentResourceName() then running=false; P.destroyAll(); watches={} end
end)
return P
