if not ContextMenuRegistry then
    local root=arg[1] or "resources/system/open77_contextmenu"
    dofile(root.."/client/registry.lua")
end
local generations={alpha=1,beta=2}
local r=ContextMenuRegistry.new(function(owner,generation) return generations[owner]==generation end)
local function definition(id)
    return {id=id or "inspect",label="Inspect",onSelect="inspect",types={"vehicle"},distance=4,networked=true}
end
local token=assert(r.register("alpha",1,definition()))
assert(not r.unregister("beta",token))
assert(not r.setEnabled("beta",token,false))
local context={target={kind="vehicle",networked=true},playerDistance=3}
assert(#r.candidates(context)==1)
context.playerDistance=5;assert(#r.candidates(context)==0)
context.playerDistance=0/0;assert(#r.candidates(context)==0)
context.playerDistance=2;context.target.networked=false;assert(#r.candidates(context)==0)
context.target.networked=true;context.target.kind="player";assert(#r.candidates(context)==0)
context.target.kind="vehicle";context.target.isLocalPlayer=true;assert(#r.candidates(context)==0)
context.target.isLocalPlayer=false;assert(r.setEnabled("alpha",token,false));assert(#r.candidates(context)==0)
assert(r.setEnabled("alpha",token,true));assert(#r.candidates(context)==1)
local replacement=assert(r.register("alpha",1,definition()))
assert(replacement~=token and not r.get(token) and #r.list("alpha")==1)
generations.alpha=3;assert(#r.candidates(context)==0)
assert(not r.register("alpha",1,definition()))
assert(not r.register("alpha",3,{id="bad",label="bad",onSelect=function()end}))
local bad=definition();bad.distance=math.huge;assert(not r.register("alpha",3,bad))
bad=definition();bad.types={vehicle=true};assert(not r.register("alpha",3,bad))
bad=definition();bad.types={"unknown"};assert(not r.register("alpha",3,bad))
bad=definition();bad.networked="true";assert(not r.register("alpha",3,bad))
bad=definition();bad.description=string.rep("a",181);assert(not r.register("alpha",3,bad))
bad=definition();bad.records={"Vehicle.taxi"};local record=assert(r.register("alpha",3,bad))
assert(#r.candidates(context)==0);context.target.record="Vehicle.taxi";assert(#r.candidates(context)==1)
assert(r.unregister("alpha",record))
for i=1,32 do assert(r.register("alpha",3,definition("a"..i))) end
assert(not r.register("alpha",3,definition("overflow")))
assert(r.register("alpha",3,definition("a1"))) -- replacing own action is allowed at quota
assert(r.register("beta",2,definition()))
r.removeOwner("alpha");assert(#r.list("alpha")==0 and #r.list("beta")==1)
generations.beta=nil;r.sweep();assert(#r.list("beta")==0)
-- Batch replacement is atomic, including a replacement followed by an error.
local original=assert(r.register("alpha",3,definition("original")))
local invalid=definition("bad");invalid.distance=-1
assert(not r.registerMany("alpha",3,{definition("original"),invalid}))
assert(r.get(original) and #r.list("alpha")==1)
assert(not r.registerMany("alpha",3,{definition("same"),definition("same")}))
local batch=assert(r.registerMany("alpha",3,{definition("one"),definition("two")}))
assert(#batch==2)
assert(not r.unregisterMany("alpha",{batch[1],"invalid"}));assert(r.get(batch[1]))
assert(r.unregisterMany("alpha",batch))
local changed=assert(r.update("alpha",3,original,{label="Updated",data={job="taxi",number=2}}))
assert(not r.get(original) and r.get(changed).label=="Updated")
assert(not r.update("beta",3,changed,{label="Stolen"}))
assert(not r.update("alpha",3,changed,{distance=-1}));assert(r.get(changed))
local copy=r.describe("alpha",changed);copy.definition.data.job="mutated"
assert(r.describe("alpha",changed).definition.data.job=="taxi")
assert(not r.describe("beta",changed))
local cyclic={};cyclic.loop=cyclic
assert(not r.update("alpha",3,changed,{data=cyclic}))
assert(not r.update("alpha",3,changed,{data={text=string.rep("x",3000)}}))
r.removeOwner("alpha")
local sky=assert(r.register("alpha",3,{id="sky",label="Look",onSelect="inspect",types={"sky"}}))
local global=assert(r.register("alpha",3,{id="all",label="All",onSelect="inspect"}))
local self=assert(r.register("alpha",3,{id="self",label="Self",onSelect="inspect",types={"player"},allowSelf=true,selfOnly=true}))
local empty={target={kind="sky",networked=false},hit=false}
assert(r.matches(r.get(sky),empty) and not r.matches(r.get(global),empty))
local me={target={kind="player",isLocalPlayer=true,playerId=3},playerDistance=1}
assert(r.matches(r.get(self),me) and not r.matches(r.get(global),me))
me.target.isLocalPlayer=false;assert(not r.matches(r.get(self),me))
local entity=assert(r.register("alpha",3,{id="specific",label="Specific",onSelect="inspect",entities={{vehicleId=7},{propId="18446744073709551000"}}}))
assert(r.matches(r.get(entity),{target={kind="vehicle",vehicleId=7},playerDistance=1}))
assert(not r.matches(r.get(entity),{target={kind="vehicle",vehicleId=8},playerDistance=1}))
assert(r.matches(r.get(entity),{target={kind="prop",propId="18446744073709551000"},playerDistance=1}))
assert(not r.update("alpha",3,entity,{entities={{engineEntity=12345}}}))
assert(not r.update("alpha",3,entity,{entities={{vehicleId=7,playerId=3}}}))
local generated=assert(r.update("alpha",3,entity,{entities={{vehicleId=4294967297}}}))
assert(r.matches(r.get(generated),{target={kind="vehicle",vehicleId=4294967297},playerDistance=1}))
assert(not r.update("alpha",3,generated,{entities={{vehicleId=1e20}}}))
-- Quota accounting is kept by index, not by a scan: every removal path must
-- free exactly what it removed, a replaced id must keep a single slot, and a
-- rolled-back batch must leave the counts where they were.
r.removeOwner("alpha")
for owner=1,6 do generations["o"..owner]=1 end
for owner=1,4 do for i=1,32 do assert(r.register("o"..owner,1,definition("a"..i))) end end
assert(not r.register("o5",1,definition()),"128 total")
assert(r.register("o1",1,definition("a7")),"replacing an id at the total limit")
assert(#r.list("o1")==32)
assert(not r.registerMany("o5",1,{definition("x"),definition("y")}))
assert(not r.register("o5",1,definition()),"a rolled-back batch frees nothing it did not take")
local listed=r.list("o1");assert(r.unregister("o1",listed[1].token))
assert(r.register("o5",1,definition("first")) and not r.register("o5",1,definition("second")))
assert(r.unregisterMany("o5",{r.list("o5")[1].token}))
assert(r.register("o1",1,definition("beyond")),"the freed slot is o1's again")
assert(not r.register("o1",1,definition("beyond2")),"o1 is back at 32 of the 128")
r.removeOwner("o2")
for i=1,32 do assert(r.register("o5",1,definition("b"..i))) end
assert(not r.register("o5",1,definition("b33")),"32 per owner")
generations.o3=nil;r.sweep()
assert(#r.list("o3")==0 and r.register("o6",1,definition()),"a sweep frees the dead owner's slots")
print("contextmenu registry: ownership, validation, quotas, filtering, revocation PASS")
