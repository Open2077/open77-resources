-- Run from repo root: lua resources/standalone/open77_freecam/tests/client.test.lua
local api,events,threads,mappings={}, {}, {}, {}
local now, caller, captured, inVehicle, supported=0,'consumer',false,false,true
local ownerGeneration=1
local held, cam, failBlock, destroyed, resets=false,nil,false,0,0
local pressed, axes={}, {mouseDeltaX=0,mouseDeltaY=0,mouseWheel=0}
local character={alive=true,attached=true,position={x=10,y=20,z=0}}
local view={position={x=10,y=20,z=1.6},forward={x=0,y=1,z=0},fov=80}
local function step()
    now=now+16
    for _,thread in ipairs(threads) do
        if coroutine.status(thread)~='dead' then local ok,why=coroutine.resume(thread);assert(ok,why) end
    end
end
function exports(name,fn) api[name]=fn end
function GetInvokingResource() return caller end
function GetInvokingResourceGeneration() return 1 end
function GetResourceState() return 'running' end
function GetCurrentResourceName() return 'open77_freecam' end
function AddEventHandler(name,fn) events[name]=fn end
RegisterNetEvent=AddEventHandler
function CreateThread(fn) threads[#threads+1]=coroutine.create(fn) end
function Wait() coroutine.yield() end
function GetGameTimer() return now end
function TriggerEvent() end
local sent
function TriggerServerEvent(...) sent={...};return true end
function RegisterKeyMapping(id,_,key,fn) mappings[id]={key=key,fn=fn} end
json={encode=function() return '{}' end}
WebUI={create=function() return nil end}
local blocks={}
Open77={camera={},players={},input={},resource={generation=function() return ownerGeneration end},character={state=function() return character end},
    session={isMenuOpen=function() return false end}}
local C,P,I=Open77.camera,Open77.players,Open77.input
function C.view() return view end
function C.create(options) cam=options;return 1 end
function C.destroy() cam=nil;held=false;destroyed=destroyed+1;return true end
function C.cameras() return {held=held,activeCamera=held and 1 or 0,
    cameras=cam and {{id=1,thirdPersonBody=supported and cam.thirdPersonBody}} or {}} end
function C.activate() held=true;return true,{await=function() return true end} end
function C.setTransform(_,pose) cam.position=pose.position;view.position=pose.position;return true end
function P.isInVehicle() return inVehicle end
function P.resetControls() blocks={};resets=resets+1;return true end
function P.getControlMask() return next(blocks) and 1 or 0 end
for _,name in ipairs({'freezePosition','freezeRotation','allowJump','allowAim','allowShoot','allowWeapons','allowInteraction','allowDodge'}) do
    P[name]=function(value) if failBlock then return false,'block_failed' end;blocks[name]=value;return true end
end
function I.isCaptured() return captured end
function I.keyFor(id) return mappings[id] and mappings[id].key end
function I.axis(name) return axes[name] end
function I.isDown(key) return pressed[key] or false end
dofile('resources/standalone/open77_freecam/config.lua')
dofile('resources/standalone/open77_freecam/client/main.lua')
mappings['freecam.toggle'].fn()
assert(sent[1]=='open77:command:execute' and sent[2]=='freecam' and sent[3]=='on' and #sent==3)
assert(api.start());step();step()
assert(api.state().phase=='active' and cam.thirdPersonBody)
local original={x=character.position.x,y=character.position.y,z=character.position.z}
pressed.forward=true
for _=1,10 do step() end
assert(cam.position.y>16 and character.position.x==original.x and character.position.y==original.y)
captured=true;local y=cam.position.y;axes.mouseDeltaX=500;step();assert(cam.position.y==y)
captured=false;pressed.forward=false;step()
axes.mouseWheel=2;pressed.CTRL=true;step();assert(api.state().fov==76)
pressed.CTRL=false;axes.mouseWheel=3;step();assert(math.abs(api.state().speed-6.9)<.001)
caller='other';local ok,why=api.stop();assert(not ok and why=='freecam_owned_by_another_resource')
caller='consumer';assert(api.stop());assert(api.state().phase=='off' and P.getControlMask()==0 and not held)
supported=false;ok,why=api.start();assert(not ok and why=='updated_freecam_client_required' and not cam)
supported=true;inVehicle=true;ok,why=api.start();assert(not ok and why=='leave_vehicle_first')
inVehicle=false;failBlock=true;assert(not api.start());assert(not cam and P.getControlMask()==0)
failBlock=false;assert(api.start());api.stop();step();assert(not held and not cam)
assert(api.start());step();step();character.alive=false;step();assert(api.state().phase=='off' and P.getControlMask()==0)
character.alive=true;assert(api.start());step();step();held=false;step();assert(api.state().phase=='off')
assert(api.start());step();step();events.onClientResourceStop('consumer');assert(api.state().phase=='off')
assert(api.start());step();step();pressed.forward=true
for _=1,2000 do step() end
local p=cam.position;assert(math.sqrt((p.x-10)^2+(p.y-20)^2+p.z^2)<=150.001)
pressed.forward=false;pressed.BACKSPACE=true;step();assert(api.state().phase=='off' and P.getControlMask()==0)
assert(destroyed==8 and resets==7)
pressed.BACKSPACE=false;assert(api.start());step();step()
ownerGeneration=2;step();assert(api.state().phase=='off' and P.getControlMask()==0)
print('freecam client lifecycle/input/range tests passed')
