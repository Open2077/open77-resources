-- Deterministic functional tests: actual library with a minimal Open77 adapter.
local root=assert(arg[1])
local threads,handlers,clock,player,geometry,draws,blips={}, {},0,{x=0,y=0,z=0},nil,{},{}
local builtinRequire=require
local modules={}
function require(name)
    if name:sub(1,9)~='@polyzone' then return builtinRequire(name) end
    if modules[name] then return modules[name] end
    local path=name=='@polyzone' and 'init' or name:sub(11)
    local result=assert(loadfile(root..'/'..path..'.lua'))()
    modules[name]=result;return result
end
function CreateThread(fn) threads[#threads+1]={co=coroutine.create(fn),due=clock} end
function Wait(ms) return coroutine.yield(ms) end
function GetCurrentResourceName() return 'test' end
function AddEventHandler(name,fn) handlers[name]=handlers[name] or {};local h={fn=fn};table.insert(handlers[name],h);return h end
function RemoveEventHandler(h) h.removed=true end
function RegisterNetEvent(name,fn) assert(type(fn)=='function','Open77 client requires a network callback');return AddEventHandler(name,fn) end
function TriggerEvent(name,...) for _,h in ipairs(handlers[name] or {}) do if not h.removed then h.fn(...) end end end
local function tick(ms)
    clock=clock+(ms or 1)
    for _,thread in ipairs({table.unpack(threads)}) do
        if thread.due<=clock and coroutine.status(thread.co)~='dead' then
            local ok,wait=coroutine.resume(thread.co);assert(ok,wait);thread.due=clock+(wait or 0)
        end
    end
end
Open77={time={monotonic=function()return clock/1000 end},character={state=function()return player and {attached=true,position=player} end},
    world={entityGeometry=function(ref)assert(type(ref)=='table' or type(ref)=='number');return geometry end},
    debugDraw={set=function(tag,spec)draws[tag]=spec;return true end,clear=function(tag)draws[tag]=nil;return true end},
    blips={create=function(spec)local id=#blips+1;blips[id]=spec;return id end,update=function(id,spec)blips[id]=spec end,remove=function(id)blips[id]=nil end}}
local PZ=assert(require('@polyzone'));local G=require('@polyzone/geometry')
assert(PZ==require('@polyzone') and PolyZone==nil)
PZ.installGlobals();assert(PolyZone==PZ.PolyZone)
local function v(x,y,z)return{x=x,y=y,z=z or 0}end
local function rejects(fn) assert(not pcall(fn),'expected validation failure') end
local shape={v(0,0),v(10,0),v(10,4),v(4,4),v(4,10),v(0,10)}
local polygon=PolyZone:Create(shape,{name='concave',minZ=-2,maxZ=5,data={job='taxi'}})
assert(polygon:isPointInside(v(2,8,5)) and not polygon:isPointInside(v(8,8)))
assert(not polygon:isPointInside(v(2,2,5.01)) and polygon.data.job=='taxi')
assert(polygon:getBoundingBoxSize().x==10 and polygon.area==64)
local raw=PolyZone:Create(shape,{useGrid=false,minZ=-2,maxZ=5})
math.randomseed(77)
for i=1,12000 do
    local p=v(math.random()*14-2,math.random()*14-2,math.random()*10-3)
    assert(polygon:isPointInside(p)==raw:isPointInside(p),'grid disagrees with winding')
end
for _,p in ipairs({v(0,0),v(10,4),v(4,10),v(4,4),v(0,10)}) do assert(polygon:isPointInside(p)==raw:isPointInside(p)) end
local eager=PolyZone:Create(shape,{lazyGrid=false,gridDivisions=8})
for i=1,40 do tick() end
for i=1,300 do local p=v(math.random()*12,math.random()*12); assert(eager:isPointInside(p)==G.winding(p,shape)) end
local before=#PZ.list()
rejects(function()PolyZone:Create({v(0,0),v(1,1),v(2,2)})end)
rejects(function()BoxZone:Create(v(0,0),1,0)end)
rejects(function()CircleZone:Create(v(0,0),0)end)
rejects(function()PolyZone:Create(shape,{gridDivisions=0})end)
assert(#PZ.list()==before,'invalid constructors leaked zones')
local box=BoxZone:Create(v(20,20),8,2,{heading=90,minZ=0,maxZ=5})
assert(box:isPointInside(v(23,20,5)) and not box:isPointInside(v(20,23)))
box:setHeading(0);assert(not box:isPointInside(v(23,20)) and box:isPointInside(v(20,23)))
box:setWidth(8);assert(box:isPointInside(v(23,20)));box:setCenter(v(100,100));assert(box:isPointInside(v(103,100)))
box:setLength(2);assert(not box:isPointInside(v(100,103)))
local scaled=BoxZone:Create(v(0,0),2,2,{minZ=0,maxZ=2,scale={2,1,1},offset={1,0,0}})
assert(scaled:isPointInside(v(0,3,2)) and not scaled:isPointInside(v(0,3.01)))
local asymmetric=BoxZone:Create(v(0,0),2,2,{scale={1,2,3,4,5,6},offset={1,2,3,4,5,6},minZ=0,maxZ=2})
assert(asymmetric:isPointInside(v(-6,-4,-11)) and not asymmetric:isPointInside(v(-6.01,-4,-11)))
local source=PZ.serialize(asymmetric)
local roundTrip=assert(load(source..'\nreturn zone'))()
assert(roundTrip.minZ==asymmetric.minZ and roundTrip.maxZ==asymmetric.maxZ and roundTrip.min.x==asymmetric.min.x)
local quoted=CircleZone:Create(v(0,0),2,{name='"\nerror("injection") --'})
assert(load(PZ.serialize(quoted)))()
local circle=CircleZone:Create(v(0,0),5,{useZ=false})
assert(circle:isPointInside(v(0,0,10000)) and not circle:isPointInside(v(5,0)))
local sphere=CircleZone:Create(v(0,0),5,{useZ=true})
assert(not sphere:isPointInside(v(0,0,5)) and sphere:isPointInside(v(0,0,4.9)))
sphere:setRadius(7);sphere:setCenter(v(1,1,1));assert(sphere:getRadius()==7)
local a=CircleZone:Create(v(0,0),3,{name='a'})
local b=CircleZone:Create(v(3,0),3,{name='b'})
local combo=ComboZone:Create({a,b},{name='both'})
assert(select(2,combo:isPointInside(v(1,0)))==a)
assert(select(2,combo:isPointInside(v(1,0),'b'))==b)
local yes,hits=combo:isPointInsideExhaustive(v(1,0));assert(yes and #hits==2)
local out={false,false,false};local _,filled=combo:isPointInsideExhaustive(v(100,100),out);assert(out==filled and #out==0)
a:setCenter(v(1000,1000));assert(combo:isPointInside(v(1000,1000)) and not combo:isPointInside(v(-1,0)))
assert(combo:RemoveZone('a')==a);combo:AddZone(a);assert(combo:RemoveZone(function(z)return z==a end)==a)
local outer=ComboZone:Create({combo});rejects(function()combo:AddZone(outer)end)
local count=#PZ.list();rejects(function()ComboZone:Create({b,{}})end);assert(#PZ.list()==count)
-- Callback semantics, overlap transitions, paused state, cancellation and nil incarnation.
a:setCenter(v(0,0));combo:AddZone(a)
local simple,combined,exhaustive={},{},{}
player=v(-20,0)
local cancel=a:onPlayerInOut(function(inside,p)simple[#simple+1]={inside,p}end,0)
combo:onPlayerInOut(function(inside,p,hit)combined[#combined+1]={inside,hit}end,0)
combo:onPlayerInOutExhaustive(function(inside,p,current,entered,left)exhaustive[#exhaustive+1]={inside,current,entered,left}end,0)
tick();assert(#simple==0 and #combined==1 and combined[1][1]==false and #exhaustive==1)
player=v(-1,0);tick();assert(#simple==1 and #combined==2 and #exhaustive==2)
player=v(1,0);tick();assert(#simple==1 and #combined==2 and #exhaustive==3 and #exhaustive[3][2]==2 and exhaustive[3][3][1]==b)
a:setPaused(true);player=v(5,0);tick();assert(#simple==1);a:setPaused(false);tick();assert(#simple==2 and simple[2][1]==false)
player=nil;tick();assert(combined[#combined][1]==false);local events=#combined;tick();assert(#combined==events)
cancel();player=v(0,0);tick();assert(#simple==2)
-- Zone events and resource/zone cleanup.
local delivered=0;AddEventHandler('taxi:zone',function(n)delivered=delivered+n end)
a:addEvent('taxi:zone');TriggerEvent('__PolyZone__:taxi:zone',2);assert(delivered==2)
player=v(50,50);TriggerEvent('__PolyZone__:taxi:zone',2);assert(delivered==2)
a:removeEvent('taxi:zone');player=v(0,0);TriggerEvent('__PolyZone__:taxi:zone',2);assert(delivered==2)
-- Entity references keep their canonical ID across stream-out / respawn.
geometry={attached=true,position=v(0,0),forward=v(0,1),orientation={x=0,y=0,z=0,w=1},bounds={min=v(-1,-2,0),max=v(1,2,3)},head=v(0,0,1.8),damage={health=100,revision=1}}
local entity=EntityZone:Create({kind='vehicle',id=12},{useZ=true})
assert(entity:isPointInside(v(0,1,3)) and not entity:isPointInside(v(0,1,4)))
local moving=ComboZone:Create({entity})
geometry.position=v(600,600);assert(moving:isPointInside(v(600,600)) and not moving:isPointInside(v(0,0)))
geometry.orientation={z=math.sqrt(.5),w=math.sqrt(.5)};geometry.forward=v(-1,0)
assert(entity:isPointInside(v(601.5,600,2)) and not entity:isPointInside(v(600,601.5,2)))
local saved=geometry;geometry=nil;assert(not moving:isPointInside(v(600,600)));geometry=saved;assert(moving:isPointInside(v(600,600)))
local damages={};entity:onEntityDamaged(function(...)damages[#damages+1]={...}end)
tick(50);geometry.damage={health=75,revision=2,attacker=77,isMelee=true};tick(50)
assert(#damages==1 and damages[1][1]==false and damages[1][2]==77 and damages[1][3]==nil and damages[1][4]==true)
geometry.damage.health=100;tick(50);assert(#damages==1)
assert(PolyZone.getPlayerHeadPosition().z==1.8)
entity:draw(true);assert(draws[entity._key] and #draws[entity._key].lines==12)
entity:destroy();assert(not draws[entity._key] and not entity:isPointInside(v(600,600)))
-- Rehydrate a value-only object without enabling metatables in a resource VM.
local restored={isCircleZone=true,name='rehydrated',center=v(0,0),radius=4,useZ=true}
assert(PolyZone.ensureMetatable(restored)==restored and restored:isPointInside(v(0,0,3)));restored:destroy()
local debug=BoxZone:Create(v(0,0),2,2,{debugPoly=true,debugBlip=true})
tick(100);assert(draws[debug._key]);assert(debug:addDebugBlip()==debug.debugBlip)
-- Real editor controller, mocked page transport and stable key mappings.
local pageHandlers,keyHandlers,lastState,focused,clipboard,backup,saveRequest={},{},nil,false,nil,nil,nil
local page={}
function page:on(name,fn)pageHandlers[name]=fn end
function page:send(name,payload)if name=='polyzone:state' then lastState=payload end end
function page:show()end
function page:hide()end
function page:setFocus(keyboard,cursor)focused=keyboard or cursor end
function page:destroy()end
WebUI={create=function(options)assert(options.layer=='menu' and options.fps==30);return page end}
function RegisterKeyMapping(name,description,key,fn)assert(type(fn)=='function');keyHandlers[key]=fn end
Open77.clipboard={setText=function(text)clipboard=text;return true end}
Open77.kvp={set=function(key,value)backup=value;return true end}
function TriggerServerEvent(name,text)assert(name=='polyzone:save');saveRequest=text end
assert(loadfile(root..'/client/main.lua'))()
TriggerEvent('onClientResourceStart','test')
TriggerEvent('polyzone:command','pzcreate',{'box','editor',4,2})
assert(focused);pageHandlers['polyzone:ready']();assert(lastState.draft.kind=='box')
TriggerEvent('polyzone:editorAction',{action='patch',minZ='0',maxZ='4',heading='35'})
assert(lastState.draft.heading==35)
TriggerEvent('polyzone:editorAction',{action='copy'});assert(clipboard:find('BoxZone:Create',1,true))
keyHandlers.F9();assert(not focused);keyHandlers.F9();assert(focused)
TriggerEvent('polyzone:command','pzfinish');assert(saveRequest==backup and lastState.draft==false)
player=v(0,0,10);TriggerEvent('polyzone:command','pzlast',{'elevated'});assert(lastState.draft.minZ==10 and lastState.draft.maxZ==14)
TriggerEvent('polyzone:command','pzcancel');assert(not focused)
player=v(0,0);TriggerEvent('polyzone:command','pzcreate',{'poly','polygon'})
player=v(1,0);keyHandlers.F10();player=v(2,0);keyHandlers.F10();assert(lastState.source=='')
player=v(2,2);keyHandlers.F10();assert(lastState.source:find('PolyZone:Create',1,true))
TriggerEvent('polyzone:command','pzundo');assert(lastState.source=='')
TriggerEvent('polyzone:command','pzcancel');tick(100)
TriggerEvent('onClientResourceStop','test');tick(100)
assert(#PZ.list()==0 and next(draws)==nil and next(blips)==nil)
assert(not focused)
print('polyzone-core: PASS (12,300 sampled containment checks, callbacks, streaming, lifecycle)')
