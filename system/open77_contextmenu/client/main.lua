local config=ContextMenuConfig
local resource=GetCurrentResourceName()
local page,ready,active,busy=nil,false,false,false
local epoch,selection,lastPickAt,nextCheck=0,nil,-1,0
local visibleActions={}
local armed=true -- A captured key is reported as released by the key-mapping host.
local disabledOwners={}
local now=function() return Open77.time.monotonic()*1000 end
local registry=ContextMenuRegistry.new(function(owner,generation)
    return GetResourceState(owner)=="running" and Open77.resource.generation(owner)==generation
end)
local function owner()
    return GetInvokingResource(),GetInvokingResourceGeneration()
end
exports("register",function(definition) local r,g=owner();return registry.register(r,g,definition) end)
exports("registerMany",function(definitions) local r,g=owner();return registry.registerMany(r,g,definitions) end)
exports("unregister",function(token) local r=owner();return registry.unregister(r,token) end)
exports("unregisterMany",function(tokens) local r=owner();return registry.unregisterMany(r,tokens) end)
exports("update",function(token,patch) local r,g=owner();return registry.update(r,g,token,patch) end)
exports("get",function(token) local r=owner();return registry.describe(r,token) end)
exports("clear",function() local r=owner();if not r then return false,"export_call_required" end;registry.removeOwner(r);return true end)
exports("setEnabled",function(token,value) local r=owner();return registry.setEnabled(r,token,value) end)
exports("list",function() local r=owner();return registry.list(r) end)
exports("isOpen",function() return active end)
exports("isReady",function() return ready and page~=nil end)
exports("getVersion",function() return "1.1.0" end)
exports("getContext",function() return selection end)
exports("getTarget",function() return selection and selection.target end)

-- Helpers are just validated filters over the same owner-scoped registry.
-- A single definition returns one token; an array returns an atomic token array.
local function scoped(definitions,filter)
    if type(definitions)~="table" then return nil,"invalid_actions" end
    local single=definitions.id~=nil
    local input=single and {definitions} or definitions
    local batch={}
    for k,d in pairs(input) do
        if type(d)~="table" then return nil,"invalid_action" end
        local action={};for field,value in pairs(d) do action[field]=value end
        for field,value in pairs(filter) do action[field]=value end
        batch[k]=action
    end
    local r,g=owner();local tokens,err=registry.registerMany(r,g,batch)
    if not tokens then return nil,err end
    return single and tokens[1] or tokens
end
exports("registerPlayers",function(d) return scoped(d,{types={"player"}}) end)
exports("registerVehicles",function(d) return scoped(d,{types={"vehicle"}}) end)
exports("registerNpcs",function(d) return scoped(d,{types={"npc"}}) end)
exports("registerProps",function(d) return scoped(d,{types={"prop"}}) end)
exports("registerDoors",function(d) return scoped(d,{types={"door"}}) end)
exports("registerWorld",function(d) return scoped(d,{types={"world"}}) end)
exports("registerSky",function(d) return scoped(d,{types={"sky"}}) end)
exports("registerSelf",function(definitions) return scoped(definitions,{types={"player"},allowSelf=true,selfOnly=true}) end)
exports("registerModels",function(records,definitions)
    if records==nil then return nil,"invalid_records" end
    return scoped(definitions,{records=records})
end)
exports("registerEntities",function(entities,definitions)
    if entities==nil then return nil,"invalid_entities" end
    return scoped(definitions,{entities=entities})
end)
local function targetingEnabled()
    for r,g in pairs(disabledOwners) do
        if GetResourceState(r)~="running" or Open77.resource.generation(r)~=g then disabledOwners[r]=nil end
    end
    return next(disabledOwners)==nil
end
exports("isTargetingEnabled",targetingEnabled)

local function send(event,payload) if page then page:send(event,payload or {}) end end
local function key() return Open77.input.keyFor("contextmenu.activate") or config.key end
local function alive()
    local state=Open77.character.state()
    return state and state.attached and state.alive and state.health and state.health>0 and state
end
local function close(reason)
    epoch=epoch+1
    local wasOpen=active
    active,busy,selection,visibleActions=false,false,nil,{}
    if page then page:setFocus(false,false);send("context:close");page:hide() end
    if Open77.players and Open77.players.resetControls then Open77.players.resetControls() end
    if wasOpen then TriggerEvent("open77:contextmenu:closed",reason or "closed") end
end
exports("close",function() close("provider_closed");return true end)
exports("setTargetingEnabled",function(value)
    local r,g=owner()
    if not r or not g then return false,"export_call_required" end
    if type(value)~="boolean" then return false,"expected_boolean" end
    disabledOwners[r]=not value and g or nil
    if not value and active then close("provider_disabled") end
    return true
end)
local function call(action,export,context,request,budget)
    local observation={};for k,v in pairs(context) do observation[k]=v end
    observation.action={id=action.id,owner=action.owner,token=action.token,data=action.data}
    local promise,reason=Open77.exports.call(action.owner,export,observation)
    if not promise then return nil,reason end
    local deadline=math.min(now()+config.exportTimeoutMs,budget or math.huge)
    while promise:status()=="pending" and now()<deadline and active and request==epoch do Wait(10) end
    if not active or request~=epoch then return nil,"cancelled" end
    if promise:status()=="pending" then return nil,"export_timeout" end
    return promise:await()
end
local function contextAt(x,y)
    local state=alive()
    if not state then return nil,"player_not_ready" end
    local hit,reason=Open77.camera.screenRaycast(x,y,config.rayDistance,{self=true})
    if not hit then return nil,reason end
    hit.screen={x=x,y=y}
    hit.hasSurface=hit.hit==true and hit.hitSource~="self_presentation"
    if not hit.hit then
        hit.target={kind="sky",networked=false};hit.kind="sky"
        hit.playerDistance=nil
        return hit
    end
    if not hit.entityLookupAvailable then return nil,"Entity picking is unavailable on this client build." end
    local p,s=hit.position,state.position
    hit.playerDistance=math.sqrt((p.x-s.x)^2+(p.y-s.y)^2+(p.z-s.z)^2)
    hit.target=hit.target or {kind="world",networked=false}
    hit.kind=hit.target.isLocalPlayer and "self" or hit.target.kind
    return hit
end
local function sameTarget(a,b)
    if not a or not b then return false end
    if a.kind~=b.kind then return false end
    if a.kind=="sky" then
        local p,q=a.direction,b.direction
        return p and q and p.x*q.x+p.y*q.y+p.z*q.z>0.9998
    end
    if a.target.engineEntity or b.target.engineEntity then return a.target.engineEntity==b.target.engineEntity end
    local p,q=a.position,b.position
    return (p.x-q.x)^2+(p.y-q.y)^2+(p.z-q.z)^2<0.04
end
local function validRequest(request)
    return active and request==epoch and page and page:hasFocus() and Open77.input.isDown(key())
end
local function pick(payload)
    if not active or busy or now()-lastPickAt<150 or type(payload)~="table" or payload.epoch~=epoch then return end
    lastPickAt=now()
    -- Preserve the click's coordinates, not the cursor's later position after IPC.
    -- They are observations only: the target is resolved by a fresh native trace.
    local cursor=Open77.input.cursor()
    if not cursor or not cursor.inBounds then return end
    local x,y=payload.x,payload.y
    if type(x)~="number" or type(y)~="number" or x~=x or y~=y or x<0 or x>1 or y<0 or y>1 then return end
    cursor={x=x,y=y}
    epoch=epoch+1;local request=epoch
    selection,visibleActions,busy=nil,{},true
    send("context:loading",{epoch=request,x=cursor.x,y=cursor.y})
    local context,reason=contextAt(cursor.x,cursor.y)
    if not context then busy=false;send("context:empty",{epoch=request,message=reason});return end
    local rows={}
    local budget=now()+config.lookupBudgetMs
    for _,action in ipairs(registry.candidates(context)) do
        if not validRequest(request) then return end
        if now()>=budget then break end
        local allowed=not action.canInteract or call(action,action.canInteract,context,request,budget)==true
        if not validRequest(request) then return end
        if allowed and registry.get(action.token)==action and registry.matches(action,context) then
            rows[#rows+1]={token=action.token,label=action.label,description=action.description,
                group=action.group,icon=action.icon,danger=action.danger}
            visibleActions[action.token]=true
            if #rows>=config.maxActions then break end
        end
    end
    if not validRequest(request) then return end
    selection,busy=context,false
    send("context:menu",{epoch=request,x=cursor.x,y=cursor.y,target=context.target, distance=context.playerDistance,actions=rows})
end
local function selectAction(payload)
    if not active or busy or type(payload)~="table" or payload.epoch~=epoch or not visibleActions[payload.token] then return end
    local action=registry.get(payload.token)
    if not action or not selection then close("action_unavailable");return end
    local request=epoch
    busy=true;send("context:busy",{epoch=request,token=payload.token})
    local current=contextAt(selection.screen.x,selection.screen.y)
    if not sameTarget(selection,current) or not registry.matches(action,current) then close("target_changed");return end
    local allowed=not action.canInteract or call(action,action.canInteract,current,request)==true
    if not validRequest(request) then return end
    -- Revalidate after a yielding predicate, not just before it.
    local fresh=contextAt(selection.screen.x,selection.screen.y)
    if not allowed or registry.get(action.token)~=action or not sameTarget(current,fresh) or not registry.matches(action,fresh) then
        busy=false;send("context:error",{epoch=request,message="This action is no longer available."});return
    end
    -- Resolve the callback from the registered owner, never from WebUI payload.
    fresh.action={id=action.id,owner=action.owner,token=action.token,data=action.data}
    local promise,reason=Open77.exports.call(action.owner,action.onSelect,fresh)
    if not promise then busy=false;send("context:error",{epoch=request,message=tostring(reason)});return end
    -- Release input before the provider opens another UI or starts an interaction.
    close("selected")
    TriggerEvent("open77:contextmenu:selected",fresh)
    local result,err=promise:await()
    if result==false or err then print("[contextmenu] action failed: "..tostring(err or "provider_rejected")) end
end
local function open()
    if not armed or not Open77.input.isDown(key()) then return end
    armed=false -- Never reopen after selection/Escape until a real key release.
    if active or not ready or not page or not targetingEnabled() or Open77.input.isCaptured() or not alive() then return end
    local cursor=Open77.input.cursor()
    if not cursor or cursor.captured then return end
    epoch=epoch+1;active=true;selection=nil;visibleActions={}
    page:show()
    if not page:setFocus(true,true) then close("focus_refused");return end
    if not Open77.players.allowAim(false) or not Open77.players.allowShoot(false) or
       not Open77.players.allowInteraction(false) or not Open77.players.freezeRotation(true) then
        close("controls_unavailable");return
    end
    send("context:open",{epoch=epoch,key=key(),appearance=config.appearance})
    TriggerEvent("open77:contextmenu:opened")
end
AddEventHandler("open77:pauseKey",function() if active then close("pause") end end)
AddEventHandler("onClientResourceStop",function(name)
    if name==resource then
        close("resource_stopped")
        if Open77.input.setNativeActionBlocked then Open77.input.setNativeActionBlocked("WeaponWheel",false) end
        page,ready=nil,false
    else registry.removeOwner(name);disabledOwners[name]=nil end
end)
AddEventHandler("onClientResourceStart",function(name)
    if name~=resource then return end
    if type(Open77.camera.screenRaycast)~="function" or type(Open77.input.cursor)~="function" then
        print("[contextmenu] Requires a client with the screen-picking APIs; package disabled.");return
    end
    local reason
    page,reason=WebUI.create({entry="web/index.html",width=1920,height=1080,fps=60,
        layer="hud",zIndex=750,transparent=true,visible=true})
    if not page then print("[contextmenu] "..tostring(reason));return end
    if config.blockNativeWeaponWheel then
        local blocked,err=false,"native_action_unavailable"
        if Open77.input.setNativeActionBlocked then blocked,err=Open77.input.setNativeActionBlocked("WeaponWheel",true) end
        if not blocked then
            print("[contextmenu] Cannot reserve the native weapon wheel: "..tostring(err))
            page:destroy();page=nil;return
        end
    end
    page:on("context:ready",function() ready=true;page:hide() end)
    page:on("context:pick",pick)
    page:on("context:select",selectAction)
    page:on("context:cancel",function(payload) if active and payload and payload.epoch==epoch then close("cancelled") end end)
    RegisterKeyMapping("contextmenu.activate","Context menu (hold)",config.key,open)
    CreateThread(function()
        while page do
            if not Open77.input.isDown(key()) then armed=true end
            if active then
                if not page:hasFocus() or not Open77.input.cursor() or not Open77.input.isDown(key()) or not alive() then close("input_released")
                elseif selection and not busy and now()>=nextCheck then
                    nextCheck=now()+config.revalidateMs
                    local current=contextAt(selection.screen.x,selection.screen.y)
                    if not sameTarget(selection,current) then close("target_changed") end
                end
            else registry.sweep() end
            Wait(active and config.activePollMs or config.idlePollMs)
        end
    end)
end)
