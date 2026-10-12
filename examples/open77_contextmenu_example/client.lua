exports("inspectTarget",function(context)
    local t=context.target
    print(("[context-example] %s engine=%s player=%s vehicle=%s npc=%s prop=%s distance=%s"):format(
        t.kind,tostring(t.engineEntity),tostring(t.playerId),tostring(t.vehicleId),
        tostring(t.npcId),tostring(t.propId),tostring(context.playerDistance)))
    print("[context-example] "..Open77.json.encode(context))
    return true
end)
local function register()
    local promise,reason=Open77.exports.call("open77_contextmenu","registerMany",{{
        id="inspect",label="Inspect target",description="Print this target's identifiers in the client log.",
        group="Developer example",icon="info",distance=8,onSelect="inspectTarget",
    },{
        id="self",label="Inspect myself",icon="person",types={"player"},allowSelf=true,selfOnly=true,
        distance=8,onSelect="inspectTarget",data={example="self"},
    },{
        id="sky",label="Use this direction",icon="location",types={"sky"},
        description="A direction only — no surface was hit.",onSelect="inspectTarget",data={example="sky"},
    }})
    if not promise then print(tostring(reason));return end
    local token,error=promise:await()
    if not token then print(tostring(error)) end
end
AddEventHandler("onClientResourceStart",function(name)
    if name==GetCurrentResourceName() or name=="open77_contextmenu" then register() end
end)
