-- Executes the actual controller with deterministic input/WebUI/export adapters.
local root=assert(arg[1])
local time,threads,handlers,methods,messages=0,{},{},{},{}
local pressed,focused,foreground,living,captured=true,false,true,true,false
local cursorCaptured=false
local wheelBlocked=false
local controls,invoking,generation,providerAlive=0,"provider",1,true
local executed,traceX,predicateMode,pendingCallback=0,nil,"ready",nil
local target="vehicle-1"
local traceKind="vehicle"
local pageEvents={}
local function run(fn,...)
    local co=coroutine.create(fn)
    local ok,delay=coroutine.resume(co,...);assert(ok,delay)
    if coroutine.status(co)~="dead" then threads[#threads+1]={co=co,due=time+(delay or 0)} end
end
local function advance(ms)
    for _=1,math.ceil(ms/10) do
        time=time+10
        local current=threads;threads={}
        for _,thread in ipairs(current) do
            if thread.due<=time then
                local ok,delay=coroutine.resume(thread.co);assert(ok,delay)
                if coroutine.status(thread.co)~="dead" then threads[#threads+1]={co=thread.co,due=time+(delay or 0)} end
            else threads[#threads+1]=thread end
        end
    end
end
function Wait(ms) return coroutine.yield(ms) end
function CreateThread(fn) run(fn) end
function AddEventHandler(name,fn) handlers[name]=fn end
function TriggerEvent() end
function GetCurrentResourceName() return "open77_contextmenu" end
function GetInvokingResource() return invoking end
function GetInvokingResourceGeneration() return generation end
function GetResourceState() return providerAlive and "running" or "stopped" end
function exports(name,fn) methods[name]=fn end
local activate
function RegisterKeyMapping(_,_,_,fn) activate=fn end
local page={}
function page:send(name,payload) messages[name]=payload end
function page:setFocus(a,b) focused=a or b;return true end
function page:hasFocus() return focused end
function page:show() return true end
function page:hide() return true end
function page:on(name,fn) pageEvents[name]=fn end
WebUI={create=function() return page end}
local function control() controls=controls+1;return true end
Open77={
    time={monotonic=function() return time/1000 end},
    resource={generation=function() return generation end},
    input={keyFor=function() return "ALT" end,isDown=function() return pressed end,
        setNativeActionBlocked=function(action,blocked) assert(action=="WeaponWheel");wheelBlocked=blocked;return true end,
        isCaptured=function() return captured end,cursor=function() if foreground then return {x=.9,y=.8,inBounds=true,captured=cursorCaptured} end end},
    character={state=function() return {attached=true,alive=living,health=living and 100 or 0,position={x=0,y=0,z=0}} end},
    players={allowAim=control,allowShoot=control,allowInteraction=control,freezeRotation=control,resetControls=function() controls=0 end},
    camera={screenRaycast=function(x,y,distance,options)
        assert(options.self==true)
        traceX=x
        if traceKind=="sky" then return {hit=false,position={x=0,y=0,z=12},origin={x=0,y=0,z=1},direction={x=0,y=0,z=1}} end
        if traceKind=="self" then return {hit=true,hitSource="self_presentation",position={x=0,y=0,z=1},entityLookupAvailable=true,target={kind="player",isLocalPlayer=true,playerId=1,engineEntity="self-body"}} end
        return {hit=true,position={x=1,y=0,z=0},entityLookupAvailable=true,
            target={kind="vehicle",engineEntity=target,networked=true,vehicleId=7}}
    end},
    exports={call=function(owner,name,context)
        assert(owner=="provider")
        if name=="allowed" then
            assert(context.action.owner==owner and context.action.id and context.action.token)
            return {status=function() return predicateMode=="timeout" and "pending" or "resolved" end,
                await=function() return predicateMode~="denied" end}
        end
        assert(name=="inspect" and context.action.owner=="provider")
        pendingCallback=context
        return {status=function() return "resolved" end,await=function()
            assert(not focused and controls==0,"provider executed before releasing input")
            executed=executed+1;return true
        end}
    end}
}
dofile(root.."/shared/config.lua")
dofile(root.."/client/registry.lua")
dofile(root.."/client/main.lua")
handlers.onClientResourceStart("open77_contextmenu");pageEvents["context:ready"]()
assert(wheelBlocked,"reserve the wheel before the first ALT gesture")
local function register(id,predicate)
    return assert(methods.register({id=id or "inspect",label="Inspect",onSelect="inspect",canInteract=predicate,types={"vehicle"}}))
end
local function open()
    pressed=false;advance(150)
    pressed,foreground,living,captured=true,true,true,false
    advance(200);activate();assert(methods.isOpen() and focused and controls==4)
end
local function pick()
    local epoch=messages["context:open"].epoch
    run(pageEvents["context:pick"],{epoch=epoch,x=.25,y=.5})
end
local function choose(token,epoch) run(pageEvents["context:select"],{epoch=epoch or messages["context:menu"].epoch,token=token}) end
local token=register()
-- No interference with another menu, dead players, or a background window.
captured=true;activate();assert(not methods.isOpen())
pressed=false;advance(150);pressed=true
captured=false;living=false;activate();assert(not methods.isOpen())
pressed=false;advance(150);pressed=true
living=true;foreground=false;activate();assert(not methods.isOpen())
pressed=false;advance(150);pressed=true
foreground=true;cursorCaptured=true;activate();assert(not methods.isOpen());cursorCaptured=false
open();pick();assert(traceX==.25,"picking must use click-time coordinates")
assert(messages["context:open"].appearance.accentColor==ContextMenuConfig.appearance.accentColor,
    "configuration must reach the browser on every open")
assert(#messages["context:menu"].actions==1)
local epoch=messages["context:menu"].epoch
choose("not-a-token",epoch);assert(executed==0)
choose(token,epoch-1);assert(executed==0)
choose(token,epoch);assert(executed==1 and not methods.isOpen() and pendingCallback.target.vehicleId==7)
activate();assert(not methods.isOpen(),"key still held must not reopen the menu")
choose(token,epoch);assert(executed==1,"replay")
-- Native re-trace is decisive, not stale browser target IDs.
open();pick();target="vehicle-2";choose(token);assert(executed==1 and not methods.isOpen())
-- Provider stop/restart invalidates registration even if the UI was already open.
open();pick();generation=2;choose(token);assert(executed==1)
pressed=false;advance(50);assert(not methods.isOpen() and controls==0)
token=register("predicate","allowed")
open();pick();predicateMode="denied";choose(token);assert(executed==1 and messages["context:error"])
pressed=false;advance(50)
predicateMode="timeout";open();pick();advance(800)
assert(#messages["context:menu"].actions==0,"timed-out predicate should not be available")
pressed=false;advance(50)
-- Pending display callbacks cannot revive a closed menu.
open();pick();pressed=false;advance(50);predicateMode="ready";advance(800)
assert(not methods.isOpen() and controls==0)
for _,reason in ipairs({"focus","foreground","death","release"}) do
    open()
    if reason=="focus" then focused=false elseif reason=="foreground" then foreground=false elseif reason=="death" then living=false else pressed=false end
    advance(50);assert(not methods.isOpen() and controls==0,reason)
end
open();handlers["open77:pauseKey"]();assert(not methods.isOpen() and controls==0)
activate();assert(not methods.isOpen(),"Escape cancellation must require a fresh press")
assert(methods.isReady() and methods.getVersion()=="1.1.0")
assert(methods.clear())
local scopedToken=assert(methods.registerVehicles({id="specific",label="Vehicle",onSelect="inspect"}))
assert(methods.get(scopedToken).definition.types[1]=="vehicle")
local many=assert(methods.registerModels({"Vehicle.test"},{{id="model",label="Model",onSelect="inspect"}}))
assert(#many==1 and methods.get(many[1]).definition.records[1]=="Vehicle.test")
assert(methods.unregisterMany(many))
assert(methods.registerEntities({{vehicleId=7}},{id="entity",label="One car",onSelect="inspect"}))
assert(not methods.registerSky({[2]={id="sparse",label="Bad",onSelect="inspect"}}))
token=assert(methods.registerSky({id="sky",label="Direction",onSelect="inspect",data={destination="sky"}}))
traceKind="sky";open();pick()
assert(#messages["context:menu"].actions==1)
assert(methods.getContext().kind=="sky" and not methods.getContext().hasSurface and not methods.getContext().playerDistance)
choose(token)
assert(pendingCallback.kind=="sky" and pendingCallback.direction.z==1 and pendingCallback.action.data.destination=="sky")
local self=assert(methods.registerSelf({id="self",label="Myself",onSelect="inspect"}))
traceKind="self";open();pick();assert(#messages["context:menu"].actions==1 and methods.getTarget().isLocalPlayer)
choose(self);assert(pendingCallback.target.playerId==1 and not pendingCallback.hasSurface)
traceKind="sky";open();pick();traceKind="vehicle";advance(250);assert(not methods.isOpen(),"sky must invalidate when a surface enters the ray")
open();assert(methods.setTargetingEnabled(false));assert(not methods.isOpen() and not methods.isTargetingEnabled())
pressed=false;advance(150);pressed=true;activate();assert(not methods.isOpen())
invoking="second";assert(methods.setTargetingEnabled(true));assert(not methods.isTargetingEnabled(),"another resource cannot release our disable claim")
invoking="provider";assert(methods.setTargetingEnabled(true));assert(methods.isTargetingEnabled())
assert(methods.setTargetingEnabled(false));handlers.onClientResourceStop("provider");assert(methods.isTargetingEnabled())
open();methods.close();assert(not methods.isOpen() and not methods.getContext())
open();handlers.onClientResourceStop("open77_contextmenu");assert(not methods.isOpen() and controls==0)
assert(not wheelBlocked,"release the native wheel on stop")
local destroyed=false
function page:destroy() destroyed=true;return true end
Open77.input.setNativeActionBlocked=function() return false,"unsupported_native_action" end
handlers.onClientResourceStart("open77_contextmenu")
assert(destroyed and not methods.isOpen(),"old client must fail closed without capturing input")
print("contextmenu controller: focus, lifecycle, click coordinates, replay, target/provider changes and callback timeout PASS")
