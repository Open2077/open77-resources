local active, definitions = {}, {}
local stopped = false
local function playerId(value)
    local player = tonumber(value)
    return player and player > 0 and player <= 9007199254740991 and player % 1 == 0 and player or nil
end
local function reply(player, raw, ok, message)
    TriggerClientEvent("open77:command:result", player, raw, ok == true, message)
    print(("[parkour] player=%s ok=%s %s"):format(player,tostring(ok),message))
end
local function policy(player,preset,mode)
    if ParkourConfig.allowedBuckets and not ParkourConfig.allowedBuckets[GetPlayerRoutingBucket(player)] then
        return false,"training_zone_required"
    end
    local ok,allowed,reason=pcall(ParkourConfig.canUse,player,preset,mode)
    if not ok or allowed ~= true then return false,reason or "parkour_access_denied" end
    return true
end
local function help()
    return "/parkour install basic|advanced ground|air|combined; /parkour inspect; /parkour test; /parkour remove. " ..
        "Ground: native dash. Air: standalone air dash. Combined: dash + existing double-jump legs (never replaced)."
end
local function testInstructions()
    return "Hold a movement direction and tap "..ParkourConfig.inputKey..". Jump then dash; with double-jump legs, "..
        "jump, jump again, then dash. One air dash per airtime; land to rearm, and wait for charges/cooldown. "..
        "Air dash then double jump is native-limited. Test walls/landing and ordinary jump after /parkour remove."
end
CreateThread(function()
    for preset,config in pairs(ParkourConfig.presets) do
        for _,mode in ipairs({"ground","air","combined"}) do
            local id="example.parkour."..preset.."."..mode
            local value={inputKey=ParkourConfig.inputKey,allowGround=mode~="air",allowAir=mode~="ground",
                requireDoubleJump=mode=="combined",movementProfile="native",presentation=ParkourConfig.presentation,
                landingRearmMs=150,
                maxAirborneMs=10000,maxFallSpeed=30}
            for key,setting in pairs(config) do value[key]=setting end
            local ok,why=Open77.dash.define({id=id,version=1,profile="dash",config=value})
            if ok then definitions[preset..":"..mode]=id
            else print("[parkour] definition unavailable "..id.." "..tostring(why)) end
        end
    end
end)

RegisterCommand("parkour",function(source,args,raw)
    local player=playerId(source)
    if not player then print("[parkour] player_command_required");return end
    local action=args[1] or "help"
    if action=="help" or action=="ui" then reply(player,raw,true,help());return end
    if action=="inspect" then
        local state,reason=Open77.dash.current(player)
        local equipment=Open77.cyberware.effective(player)
        local legs=equipment and equipment.legs
        local details=state and ("status=%s phase=%s definition=%s charges=%s airUsed=%s cooldownUntil=%s nextChargeAt=%s activation=%s")
            :format(state.projection.status,state.phase or "idle",state.projection.definition and state.projection.definition.id or "none",
                state.charges,tostring(state.airUsed),state.cooldownUntil,state.nextChargeAt,tostring(state.activation)) or
            ("Dash absent: "..tostring(reason or "no_grant"))
        reply(player,raw,true,details.."; legs="..(legs and legs.profile or "none").."; paid equipment unchanged")
        return
    end
    if action=="test" then
        local state=Open77.dash.current(player)
        if not state then reply(player,raw,false,"Install a preset first. "..help());return end
        reply(player,raw,true,testInstructions().." Native readiness="..tostring(state.projection.status));return
    end
    if action=="remove" then
        local ok,why=Open77.dash.revoke(player)
        if ok then active[player]=nil end
        reply(player,raw,ok~=nil,ok and "Dash removed; existing arms and double-jump legs remain installed." or tostring(why));return
    end
    if action~="install" then reply(player,raw,false,help());return end
    local preset,mode=args[2] or "basic",args[3] or "air"
    local definition=definitions[preset..":"..mode]
    if not definition then reply(player,raw,false,"Unknown/unavailable preset. "..help());return end
    local allowed,why=policy(player,preset,mode)
    if not allowed then reply(player,raw,false,tostring(why));return end
    if mode=="combined" then
        local equipment=Open77.cyberware.effective(player)
        if not equipment or not equipment.legs or equipment.legs.profile~="double_jump" then
            reply(player,raw,false,"Combined requires existing double-jump legs. Ask an authorized doctor: /doc offer "..
                player.." training legs, then accept the offer. Your existing paid slots are never replaced by /parkour.");return
        end
    end
    local ok,reason=Open77.dash.grant(player,definition)
    if ok then active[player]={preset=preset,mode=mode} end
    reply(player,raw,ok~=nil,ok and ("Dash grant requested; /parkour inspect checks native readiness. "..testInstructions()) or tostring(reason))
end,false)

AddEventHandler("onDashChanged",function(source,encoded)
    local player=playerId(source)
    if not player or not active[player] then return end
    local ok,value=pcall(json.decode,encoded)
    if not ok or type(value)~="table" then return end
    -- Correlated diagnostics, not visual acceptance evidence.
    print(("[parkour] player=%s activation=%s phase=%s reason=%s"):format(player,
        tostring(value.activation),tostring(value.phase),tostring(value.reason)))
end)
AddEventHandler("onDashRejected",function(source,encodedPermit)
    local player=playerId(source)
    if not player or not active[player] then return end
    local ok,value=pcall(json.decode,encodedPermit)
    if not ok or type(value)~="table" then return end
    -- A rejected intent never receives an activation ID; the request sequence correlates it.
    print(("[parkour] player=%s rejected sequence=%s reason=%s"):format(player,
        tostring(value.sequence),tostring(value.error)))
end)
AddEventHandler("onPlayerDisconnected",function(player) active[tonumber(player)]=nil end)
AddEventHandler("onResourceStop",function() stopped=true end)
CreateThread(function()
    while not stopped do
        Wait(250)
        for player,selection in pairs(active) do
            local state=Open77.dash.current(player)
            local allowed=policy(player,selection.preset,selection.mode)
            if not state then active[player]=nil
            elseif not allowed then
                local ok=Open77.dash.revoke(player)
                if ok then active[player]=nil end
            end
        end
    end
end)
