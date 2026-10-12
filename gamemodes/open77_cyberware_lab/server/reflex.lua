-- Resource-owned session ability, through public APIs only. Paid equipment is
-- read-only, and no clock is touched anywhere in this file or below it: the
-- reflex overdrive is a real-time buff that speeds its owner up. It does not
-- slow bullets and it does not slow other players. Genuine shared slow motion
-- is a separate, separately gated experiment (plan section 8).
CyberwareLabReflex={}
local config=CyberwareLab.reflex
local definitions,active,lastAction={},{},{}
local stopped=false
local function id(v)
    local n=tonumber(v);return n and n>0 and n<=9007199254740991 and n%1==0 and n or nil
end
local function policy(issuer,target,preset)
    if config.allowedBuckets and not config.allowedBuckets[GetPlayerRoutingBucket(target)] then return false,"training_zone_required" end
    local ok,allowed,reason=pcall(config.canUse,issuer,target,preset)
    return ok and allowed==true,reason or "reflex_access_denied"
end
local function manageable(target,current)
    if not current then return true end
    return current.ownedByCaller==true
end
local function hint()
    return "Close this panel and tap "..string.upper(config.inputKey).." to engage (the Overdrive action is rebindable under Pause > Settings > Key Bindings). The world keeps running at normal speed: "..
        "you move, swing and reload faster, nobody else is slowed and no bullet is slowed. "..
        "It ends on its own deadline, and also on death, a vehicle, a workspot and a reconnect. "..
        "The cooldown starts when the boost ends. Dash and Ground Slam stay usable under it."
end
function CyberwareLabReflex.snapshot(target)
    local api=Open77.reflex
    local current,reason
    if api then current,reason=api.current(target) end
    local owned=manageable(target,current)
    if not owned then reason="grant_owned_by_another_resource" end
    local details={}
    for _,preset in ipairs({"street","combat"}) do
        local value=config.presets[preset] or {}
        details[preset]={tier=value.tier,durationMs=value.durationMs,cooldownMs=value.cooldownMs,
            maxCharges=value.maxCharges,chargeRegenMs=value.chargeRegenMs,staminaCost=value.staminaCost}
    end
    local stats=Open77.stats and Open77.stats.get(target)
    local pool=stats and stats.stamina
    return {available=api~=nil and next(definitions)~=nil,current=current,reason=reason,manageable=owned,
        capabilities=api and api.capabilities(),presets={"street","combat"},
        inputKey=config.inputKey,presetDetails=details,hint=hint(),
        stamina=type(pool)=="table" and pool.value or pool}
end
CreateThread(function()
    if not Open77.reflex then return end
    for _,preset in ipairs({"street","combat"}) do
        local definition="cyberlab.reflex."..preset
        local settings={inputKey=config.inputKey,presentation=config.presentation}
        for k,v in pairs(config.presets[preset] or {}) do settings[k]=v end
        local result=Open77.reflex.define({id=definition,version=1,profile="reflex_overdrive",config=settings})
        if result and result.ok then definitions[preset]=definition end
    end
end)
function CyberwareLabReflex.operate(issuer,target,action,preset)
    target=id(target);issuer=tonumber(issuer) or 0
    if not target or Open77.players.name(target)==nil then return false,"player_unavailable" end
    if not Open77.reflex then return false,"reflex_unavailable" end
    if action=="inspect" then
        local value=Open77.reflex.current(target)
        return true,value and ("Reflex "..tostring(value.projection.status).."; phase="..tostring(value.phase)..
            "; charges="..tostring(value.charges).."; remainingMs="..tostring(value.remainingMs)) or
            "Reflex absent; paid equipment unchanged."
    end
    if action=="test" then
        if not Open77.reflex.current(target) then return false,"Grant a Reflex preset first." end
        return true,hint()
    end
    if action=="cancel" then
        if not manageable(target,Open77.reflex.current(target)) then return false,"grant_owned_by_another_resource" end
        local result,reason=Open77.reflex.cancel(target)
        if not result or not result.ok then return false,reason or (result and result.error) or "no_activation" end
        return true,"Overdrive cancelled; the grant and its cooldown are unchanged."
    end
    if action~="grant" and action~="revoke" then return false,"invalid_action" end
    preset=preset or "street"
    if action=="grant" and preset~="street" and preset~="combat" then return false,"unknown_or_unavailable_preset" end
    local now=GetGameTimer();local key=tostring(issuer)
    if lastAction[key] and now-lastAction[key]<500 then return false,"rate_limit" end
    lastAction[key]=now
    if action=="grant" then
        if not manageable(target,Open77.reflex.current(target)) then return false,"grant_owned_by_another_resource" end
        local allowed,reason=policy(issuer,target,preset)
        if not allowed then return false,reason end
        local definition=definitions[preset]
        if not definition then return false,"unknown_or_unavailable_preset" end
        local result,failure=Open77.reflex.grant(target,definition)
        if not result or not result.ok then return false,failure or (result and result.error) or "grant_refused" end
        active[target]={issuer=issuer,preset=preset}
        return true,"Reflex grant requested; inspect native readiness. "..hint()
    end
    if not manageable(target,Open77.reflex.current(target)) then return false,"grant_owned_by_another_resource" end
    local result,reason=Open77.reflex.revoke(target)
    if not result or not result.ok then return false,reason or (result and result.error) or "revoke_refused" end
    active[target]=nil
    return true,"Reflex removed; paid arms and legs unchanged."
end
function CyberwareLabReflex.command(issuer,args)
    if args[1]=="grant" and (args[2]=="street" or args[2]=="combat") then
        return CyberwareLabReflex.operate(issuer,issuer,"grant",args[2])
    end
    return CyberwareLabReflex.operate(issuer,args[2] or issuer,args[1] or "inspect",args[3])
end
AddEventHandler("onPlayerDisconnected",function(player)
    active[tonumber(player)]=nil;lastAction[tostring(player)]=nil
end)
AddEventHandler("onResourceStop",function() stopped=true end)
-- The refused/accepted stream, so a lab operator sees why a tap did nothing.
AddEventHandler("onReflexRejected",function(player,payload)
    local value=json.decode(payload)
    if value and value.error then print("[cyberlab reflex] player="..tostring(player).." refused="..tostring(value.error)) end
end)
AddEventHandler("onReflexChanged",function(player,payload)
    local value=json.decode(payload)
    if value then print("[cyberlab reflex] player="..tostring(player).." phase="..tostring(value.phase)..
        " tier="..tostring(value.tier).." reason="..tostring(value.reason)) end
end)
CreateThread(function()
    while not stopped do
        Wait(250)
        if stopped then return end
        for target,value in pairs(active) do
            local state=Open77.reflex.current(target)
            if not state or not manageable(target,state) then active[target]=nil
            elseif not policy(value.issuer,target,value.preset) then
                local result=Open77.reflex.revoke(target)
                if result and result.ok then active[target]=nil end
            end
        end
    end
end)

-- Panel plumbing, the same shape as ground-slam.lua: a read route the page asks
-- on open and on refresh, an action route with a per-issuer rate limit, and one
-- data push after every action so the card never shows a stale grant.
local reads, panelActions = {}, {}
local function connected(value)
    local n=id(value);return n and Open77.players.name(n) and n or nil
end
local function send(issuer,suffix,value)
    if connected(issuer) then TriggerClientEvent("open77:cyberlab:reflex:"..suffix,issuer,value) end
end
local function panelSnapshot(target)
    local value=CyberwareLabReflex.snapshot(target)
    value.target=target
    return value
end
RegisterNetEvent("open77:cyberlab:reflex:request",function(payload)
    local issuer=connected(source)
    if not issuer or type(payload)~="table" then return end
    local target=payload.target==nil and issuer or connected(payload.target)
    if not target then return end
    local t=GetGameTimer();if reads[issuer] and t-reads[issuer]<100 then return end;reads[issuer]=t
    send(issuer,"data",panelSnapshot(target))
end)
RegisterNetEvent("open77:cyberlab:reflex:action",function(payload)
    local issuer=connected(source)
    if not issuer or type(payload)~="table" then return end
    local target=payload.target==nil and issuer or id(payload.target)
    if not target then return end
    local t=GetGameTimer();if panelActions[issuer] and t-panelActions[issuer]<200 then return end;panelActions[issuer]=t
    local ok,reason=CyberwareLabReflex.operate(issuer,target,payload.action,payload.preset)
    send(issuer,"result",{target=target,ok=ok,message=ok and tostring(reason) or tostring(reason)})
    if connected(target) then send(issuer,"data",panelSnapshot(target)) end
end)
AddEventHandler("onPlayerDisconnected",function(player)
    player=id(player);if player then reads[player]=nil;panelActions[player]=nil end
end)

