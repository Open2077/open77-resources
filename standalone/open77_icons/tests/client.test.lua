-- Run from repository root with Lua 5.4. No game, files or network modified.
local api, events, threads, live = {}, {}, {}, {}
local owner, generation, nextId, failUpdate = "shop", 1, 0, false
local states, gens = {shop="running", hospital="running", jobs="running"}, {shop=1, hospital=1, jobs=1}
function exports(name, callback) api[name] = callback end
function GetInvokingResource() return owner end
function GetInvokingResourceGeneration() return generation end
function GetCurrentResourceName() return "open77_icons" end
function GetResourceState(name) return states[name] or "stopped" end
function AddEventHandler(name, callback) events[name] = callback end
function CreateThread(callback) threads[#threads+1] = coroutine.create(callback) end
function Wait() coroutine.yield() end
Open77 = { resource={generation=function(name) return gens[name] end}, blips={} }
function Open77.blips.create(options)
    if options.position == nil then return nil, "position_required" end
    nextId = nextId+1
    local id = tostring(nextId)
    live[id] = options
    return id
end
function Open77.blips.remove(id) local exists=live[id]~=nil; live[id]=nil; return exists end
function Open77.blips.update(id, options)
    if failUpdate then return false, "native_quota" end
    if not live[id] then return false, "not_found" end
    for key,value in pairs(options) do live[id][key]=value end
    return true
end
function Open77.blips.setColor() return true end
function Open77.blips.get(id) return live[id] end
function Open77.blips.track(id) return live[id]~=nil end
Open77.blips.untrack = Open77.blips.track
dofile("resources/standalone/open77_icons/client/catalogue.lua")
dofile("resources/standalone/open77_icons/client/main.lua")
local checks=0
local function eq(actual, expected) checks=checks+1; assert(actual==expected, tostring(actual).." ~= "..tostring(expected)) end
local function reject(expected, fn, ...) local value,reason=fn(...); eq(not value,true); eq(reason,expected) end
local function create(icon) return api.create({icon=icon or "fuel", position={x=1,y=2,z=3}}) end
eq(api.info().count,2112); eq(api.info().apiAvailable,true)
eq(api.has("LUCIDE:FUEL"),true); eq(api.has("../fuel"),false)
eq(api.list("fuel").icons[1],"fuel")
eq(#api.list("",0,100).icons,100)
eq(api.list("",100,1).icons[1],api.list("",99,2).icons[2])
eq(api.list("not-an-icon").total,0)
reject("invalid_limit",api.list,"",0,101)
reject("invalid_offset",api.list,"",0/0,20)
reject("unknown_icon",create,"../fuel")
reject("icon_required",api.create,{})
reject("unsupported_option:unknown",api.create,{icon="fuel",unknown=true})
reject("invalid_icon_size",api.create,{icon="fuel",size=0/0})
local id=assert(create("LUCIDE:FUEL"))
eq(live[id].icon.asset,"icons/lucide/fuel.svg"); eq(live[id].icon.size,48)
eq(api.setIcon(id,"hospital",32),true)
eq(live[id].icon.asset,"icons/lucide/hospital.svg")
eq(api.update(id,{size=40}),true); eq(live[id].icon.size,40)
eq(api.setColor(id,"#FFCC00"),true); eq(live[id].color,"#FFCC00")
eq(api.track(id),true); eq(api.get(id),live[id])
reject("routable_is_create_only",api.update,id,{routable=true})
reject("invalid_position",api.setPosition,id,nil)
reject("invalid_active",api.setActive,id,1)
failUpdate=true
reject("native_quota",api.setIcon,id,"car",64)
failUpdate=false
eq(api.update(id,{size=36}),true)
eq(live[id].icon.asset,"icons/lucide/hospital.svg") -- failed update must not change metadata
eq(api.setIcon(id,false),true); eq(live[id].icon,false)
eq(api.setIcon(id,"fuel"),true); eq(live[id].icon.size,36)
owner="hospital"
reject("blip_not_owned",api.remove,id)
reject("blip_not_owned",api.setIcon,id,"car")
reject("blip_not_owned",api.track,id)
local other=assert(create())
owner="shop"
eq(api.clear(),1); eq(live[id],nil); eq(live[other]~=nil,true)
for _=1,64 do assert(create()) end
reject("icon_blip_limit",create)
owner="hospital"
for _=1,63 do assert(create()) end
owner="jobs"
reject("icon_blip_limit",create)
owner="shop"; generation=2; gens.shop=2
local reloaded=assert(create()) -- previous generation's 64 handles discarded
eq(api.clear(),1)
owner="hospital"; generation=1
eq(api.clear(),64)
local stopped=assert(create())
states.hospital="stopped"
assert(coroutine.resume(threads[1])); assert(coroutine.resume(threads[1]))
eq(live[stopped],nil)
states.hospital="running"
local old=assert(create())
gens.hospital=3
assert(coroutine.resume(threads[1])); eq(live[old],nil)
generation=3
local latest=assert(create())
events.onClientResourceStop("hospital"); eq(live[latest],nil)
assert(create())
events.onClientResourceStop("open77_icons"); eq(next(live),nil)
owner=nil
reject("export_call_required",create)
owner="shop"; generation=2
Open77.blips.setColor=nil
reject("svg_client_required",create)
print("open77_icons: "..checks.." assertions passed")
