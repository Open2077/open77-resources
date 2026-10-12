-- Actual client resource, with native calls accepting an activation that fails
-- to stick, then delivering its auto-off event after the callback returns.
local handlers,net,exported,threads,wire={},{},{},{},{}
local active=false
local native={}
local refuse=false
local failOutfit=false
local mutationReady=false
local gateAvailable=true
local applications=0
local visualsSettled=true
local function clone(t)local r={};for k,v in pairs(t)do r[k]=v end;return r end
Open77={exports={call=function(resource,name)
 assert(resource=="open77_appearance" and name=="wardrobeMutationReady","use lifecycle gate, not appearance clothing readiness")
 if not gateAvailable then return nil,"resource_unavailable" end
 return {await=function()return mutationReady end}
end},equipment={},puppets={setWardrobe=function()end},
 session={characterBootstrap=function()return{phase="ready",playerReset="complete"}end},
 character={state=function()return{alive=true}end},wardrobe={}}
function Open77.wardrobe.active()return active end
function Open77.equipment.registry()return {} end
function Open77.equipment.info()return {} end
function Open77.equipment.visualSettled()return visualsSettled end
function Open77.wardrobe.activate(value)if refuse then active=false else active=value end;return true end
function Open77.wardrobe.outfit(index)return{
 apply=function(items)applications=applications+1;if failOutfit then return nil,"native_refused" end;native[index]=clone(items);return true end,
 registry=function()return native[index] end}end
function AddEventHandler(name,fn)handlers[name]=fn end
function RegisterNetEvent(name,fn)net[name]=fn end
function TriggerServerEvent(name,...)wire[#wire+1]={name=name,args={...}}end
function CreateThread(fn)threads[#threads+1]=coroutine.create(fn)end
function Wait()coroutine.yield()end
function exports(name,fn)exported[name]=fn end
function GetInvokingResource()return"open77_wardrobe_ui"end
local function tick()assert(coroutine.resume(threads[1]))end
dofile("resources/open77_wardrobe/client/main.lua")
tick()
local expected={active=0,outfits={[0]={Head="Items.Hat",Outfit=false}}}
net["open77:wardrobe:self"](expected)
tick()
assert(applications==0 and active==false,"open or unconfirmed mirror must block wardrobe application")
gateAvailable=false;tick()
assert(applications==0,"missing appearance gate must fail closed")
gateAvailable=true;mutationReady=true
tick();tick()
assert(applications==7 and active==0,"mirror confirmation must resume pending state without waiting on garments")
mutationReady=false;active=false
handlers["open77:wardrobe:active"](-1)
assert(#wire==0,"native changes during appearance editing must not publish")
mutationReady=true
refuse=true
net["open77:wardrobe:self"](expected)
handlers["open77:wardrobe:active"](-1)
assert(#wire==0,"accepted-but-unapplied activation must not publish auto-off")
assert(not exported.beginPreview(),"unverified restoration must prevent another preview")
tick();handlers["open77:wardrobe:active"](-1);assert(#wire==0)
refuse=false;tick();tick()
assert(exported.beginPreview(),"confirmed active zero and hidden slots release pending state")
active=6;native[0]={Head=false}
assert(exported.endPreview())
-- Equipment's subsequent restoration switches vanilla wardrobe off after the
-- wardrobe owner's endPreview returned, before its queued events are delivered.
active=false;handlers["open77:wardrobe:active"](-1)
assert(#wire==0,"late automatic disable during restoration must not become intent")
tick();tick();assert(active==0 and native[0].Outfit==false)
assert(exported.beginPreview());failOutfit=true;assert(exported.endPreview())
handlers["open77:wardrobe:outfit"](0,"Head=-")
assert(#wire==0,"failed outfit restoration must suppress native mutations")
failOutfit=false;tick();tick()
assert(exported.beginPreview())
visualsSettled=false;assert(exported.endPreview())
local before=applications
tick()
assert(applications>before,"matching registries with stale native appearance must reapply projection")
assert(not exported.beginPreview(),"unsettled visual restoration must retain the preview barrier")
handlers["open77:wardrobe:active"](-1)
assert(#wire==0,"visual repair must not publish intermediate engine intent")
visualsSettled=true;tick()
assert(exported.beginPreview(),"confirmed visual restoration must release the barrier")
assert(exported.endPreview());tick()
active=false;handlers["open77:wardrobe:active"](-1)
assert(#wire==1 and wire[1].name=="open77:wardrobe:active","real changes publish after verified restoration")
print("Wardrobe restoration: failed activation, late auto-off, failed outfit, index zero and hide readback passed")
