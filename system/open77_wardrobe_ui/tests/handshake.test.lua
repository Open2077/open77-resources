-- Exercises the actual resource controller with its initial browser-ready
-- event deliberately dropped. No game mutation or native build is required.
local callbacks, net, exported, threads, sent, wire = {}, {}, {}, {}, {}, {}
local time, captured, mapping = 1, false, nil
local page={}
function page:on(name, fn) callbacks[name]=fn end
function page:send(name, value) sent[#sent+1]={name=name,value=value};return true end
function page:setFocus(keyboard) captured=keyboard;return true end
WebUI={create=function() return page end}
function GetCurrentResourceName() return "open77_wardrobe_ui" end
function RegisterNetEvent(name, fn) net[name]=fn end
function AddEventHandler(name, fn) callbacks[name]=fn end
function exports(name, fn) exported[name]=fn end
function CreateThread(fn) threads[#threads+1]=coroutine.create(fn) end
function Wait(_) coroutine.yield() end
function TriggerServerEvent(name, ...) wire[#wire+1]=name;return true end
function TriggerEvent() end
function RegisterKeyMapping(_,_,key,_) mapping=key end
Open77={time={monotonic=function() return time end},input={isCaptured=function() return captured end},
 session={characterBootstrap=function()return{phase="ready",playerReset="complete"}end},
 character={state=function()return{alive=true,vehicle={mounted=false}}end},
 players={getLifeState=function()return{phase="alive"}end},
 exports={call=function()return{await=function()return true end}end},
 perspective={state=function()return{requested="fpp"}end,get=function()return"fpp"end,set=function()return true end},
 camera={clearOrbit=function()end,orbit=function()return true end}}
dofile("resources/system/open77_wardrobe_ui/client/main.lua")
callbacks.onClientResourceStart("open77_wardrobe_ui")
assert(mapping=="F2","wardrobe must not collide with hardcoded native F7 perspective")
net["open77:wardrobe_ui:open"]()
assert(exported.state().pendingOpen and not exported.state().ready)
assert(coroutine.resume(threads[1]));assert(sent[#sent].name=="wardrobe:probe")
callbacks["wardrobe:ready"]()
time=time+0.25;assert(coroutine.resume(threads[1]))
assert(wire[#wire]=="open77:presentation:uiRequest" and exported.state().opening)
net["open77:presentation:uiState"]({available=true,revision=1,characterKey="test",family="female",equipment={},wardrobe={outfits={}}})
assert(exported.state().opened and captured)
assert(sent[#sent].name=="wardrobe:open")
local orbitReady, orbitCalls = true, 0
Open77.camera.orbit=function() orbitCalls=orbitCalls+1;return orbitReady end
time=time+0.25;assert(coroutine.resume(threads[1]))
assert(orbitCalls==1)
orbitReady=false
time=time+0.25;assert(coroutine.resume(threads[1]))
assert(orbitCalls==2,"camera suspension must be observed after initial orbit success")
orbitReady=true
time=time+0.25;assert(coroutine.resume(threads[1]))
assert(orbitCalls==3 and exported.state().opened,"preview must resume without reopening the menu")
time=600;callbacks["wardrobe:activity"]()
time=602;assert(coroutine.resume(threads[1]))
assert(exported.state().opened,"typing must extend the idle deadline beyond the initial open")
time=1201;assert(coroutine.resume(threads[1]))
assert(not exported.state().opened and not captured,"ten minutes without activity still releases the fitting room")
callbacks["wardrobe:close"]()
assert(not exported.state().opened and not captured)
print("Wardrobe controller: dropped initial ready recovered by probe, queued open completed, F2 mapping and close focus cleanup passed")
