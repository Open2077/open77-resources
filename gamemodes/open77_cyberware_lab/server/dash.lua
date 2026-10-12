-- Resource-owned session ability, through public APIs only. Paid equipment is read-only.
CyberwareLabDash={}
local config=CyberwareLab.dash
local definitions,active,lastAction={},{},{}
local stopped=false
local function id(v)
    local n=tonumber(v);return n and n>0 and n<=9007199254740991 and n%1==0 and n or nil
end
local function policy(issuer,target,preset,mode)
    if config.allowedBuckets and not config.allowedBuckets[GetPlayerRoutingBucket(target)] then return false,"training_zone_required" end
    local ok,allowed,reason=pcall(config.canUse,issuer,target,preset,mode)
    return ok and allowed==true,reason or "dash_access_denied"
end
local function manageable(target,current)
    if not current then return true end
    return current.ownedByCaller==true
end
local function hint()
    return "Close this panel. Hold forward/back/left/right and tap "..config.inputKey..". Jump then dash; with double-jump legs, jump twice then dash. "..
        "One air dash per airtime; land to rearm and wait for charges/cooldown. Air dash then double jump is native-limited. Test walls and ordinary jumping after removal."
end
function CyberwareLabDash.snapshot(target)
    local api=Open77.dash
    local current,reason
    if api then current,reason=api.current(target) end
    local owned=manageable(target,current)
    if not owned then reason="grant_owned_by_another_resource" end
    local details={}
    for _,preset in ipairs({"basic","advanced"}) do
        local value=config.presets[preset] or {}
        details[preset]={staminaCost=value.staminaCost,cooldownMs=value.cooldownMs,maxCharges=value.maxCharges,chargeRegenMs=value.chargeRegenMs}
    end
    local stats=Open77.stats and Open77.stats.get(target)
    local pool=stats and stats.stamina
    return {available=api~=nil and next(definitions)~=nil,current=current,reason=reason,manageable=owned,
        capabilities=api and api.capabilities(),presets={"basic","advanced"},modes={"ground","air","combined"},
        inputKey=config.inputKey,presetDetails=details,hint=hint(),stamina=type(pool)=="table" and pool.value or pool}
end
CreateThread(function()
    if not Open77.dash then return end
    for _,preset in ipairs({"basic","advanced"}) do
        for _,mode in ipairs({"ground","air","combined"}) do
            local definition="cyberlab.dash."..preset.."."..mode
            local settings={inputKey=config.inputKey,presentation=config.presentation,movementProfile="native",
                allowGround=mode~="air",allowAir=mode~="ground",requireDoubleJump=mode=="combined",
                landingRearmMs=150,maxAirborneMs=10000,maxFallSpeed=30}
            for k,v in pairs(config.presets[preset] or {}) do settings[k]=v end
            local result=Open77.dash.define({id=definition,version=1,profile="dash",config=settings})
            if result and result.ok then definitions[preset..":"..mode]=definition end
        end
    end
end)
function CyberwareLabDash.operate(issuer,target,action,preset,mode)
    target=id(target);issuer=tonumber(issuer) or 0
    if not target or Open77.players.name(target)==nil then return false,"player_unavailable" end
    if not Open77.dash then return false,"dash_unavailable" end
    if action=="inspect" then
        TriggerClientEvent("open77:dashInspect",target)
        local value=Open77.dash.current(target)
        return true,value and ("Dash "..tostring(value.projection.status).."; phase="..tostring(value.phase).."; charges="..tostring(value.charges).."; airUsed="..tostring(value.airUsed)) or "Dash absent; paid equipment unchanged."
    end
    if action=="test" then
        if not Open77.dash.current(target) then return false,"Install a Dash preset first." end
        return true,hint()
    end
    if action~="install" and action~="remove" then return false,"invalid_action" end
    preset=preset or "basic";mode=mode or "air"
    if action=="install" and ((preset~="basic" and preset~="advanced") or (mode~="ground" and mode~="air" and mode~="combined")) then
        return false,"unknown_or_unavailable_preset"
    end
    local now=GetGameTimer();local key=tostring(issuer)
    if lastAction[key] and now-lastAction[key]<500 then return false,"rate_limit" end
    lastAction[key]=now
    -- Revocation remains possible after leaving a zone or losing progression.
    if action=="install" then
        if not manageable(target,Open77.dash.current(target)) then return false,"grant_owned_by_another_resource" end
        local allowed,reason=policy(issuer,target,preset,mode)
        if not allowed then return false,reason end
        local definition=definitions[preset..":"..mode]
        if not definition then return false,"unknown_or_unavailable_preset" end
        if mode=="combined" then
            local record=Open77.cyberware.current(target)
            local effective=Open77.cyberware.effective(target)
            if not record or not record.legs or record.legs.profile~="double_jump" or not effective or not effective.legs or effective.legs.profile~="double_jump" then
                return false,"Combined requires installed double-jump legs. Use the Double Jump tab or an authorized doctor; Dash never replaces paid equipment."
            end
        end
        local result,reason=Open77.dash.grant(target,definition)
        if not result or not result.ok then return false,reason or (result and result.error) or "grant_refused" end
        active[target]={issuer=issuer,preset=preset,mode=mode}
        return true,"Dash grant requested; inspect native readiness. "..hint()
    end
    if not manageable(target,Open77.dash.current(target)) then return false,"grant_owned_by_another_resource" end
    local result,reason=Open77.dash.revoke(target)
    if not result or not result.ok then return false,reason or (result and result.error) or "revoke_refused" end
    active[target]=nil
    return true,"Dash removed; paid arms and double-jump legs unchanged."
end
function CyberwareLabDash.command(issuer,args)
    if args[1]=="install" and (args[2]=="basic" or args[2]=="advanced") then
        return CyberwareLabDash.operate(issuer,issuer,"install",args[2],args[3])
    end
    return CyberwareLabDash.operate(issuer,args[2] or issuer,args[1] or "inspect",args[3],args[4])
end
AddEventHandler("onPlayerDisconnected",function(player)
    active[tonumber(player)]=nil;lastAction[tostring(player)]=nil
end)
AddEventHandler("onResourceStop",function() stopped=true end)
CreateThread(function()
    while not stopped do
        Wait(250)
        if stopped then return end
        for target,value in pairs(active) do
            local state=Open77.dash.current(target)
            if not state or not manageable(target,state) then active[target]=nil
            elseif not policy(value.issuer,target,value.preset,value.mode) then
                local result=Open77.dash.revoke(target)
                if result and result.ok then active[target]=nil end
            end
        end
    end
end)
