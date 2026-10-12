-- Optional lab fixture: synthetic sessions remain synthetic sessions.
local batch, stopping = nil, false
local function report(value)
    local live, ids = 0, {}
    for _, id in ipairs(value.ids) do
        if Open77.effects.get(id) then live=live+1; ids[#ids+1]=id end
    end
    return json.encode({accepted=value.accepted,rejected=value.rejected,errors=value.errors,
        registryLive=live,ids=ids,expiresAt=value.expires,targets=value.targets})
end
local function cancel(reason)
    local value = batch
    batch = nil
    if not value then return true, 'load_idle' end
    for _, id in ipairs(value.ids) do pcall(Open77.effects.remove,id) end
    print('[cyberware load] stopped='..reason..' '..report(value))
    return true, 'load_stopped'
end
function CyberwareLabLoad(issuer,args)
    local verb = args[2]
    if verb == 'cancel' then return cancel('command') end
    if verb == 'status' then return true, batch and report(batch) or 'load_idle' end
    if verb ~= 'start' then return false, 'load start <ttlMs:1000-60000> <playerIdsCSV:max32> <visual|audio> [effect] [soundEvent] | status | cancel' end
    if stopping or batch then return false, stopping and 'resource_stopping' or 'load_already_running' end
    local ttl, csv, mode = tonumber(args[3]), args[4], args[5]
    if not ttl or ttl%1~=0 or ttl<1000 or ttl>60000 then return false,'invalid_ttl' end
    if type(csv)~='string' or #csv>640 or not csv:match('^%d[%d,]*%d$') and not csv:match('^%d$')
        or csv:find(',,',1,true) then return false,'invalid_targets' end
    if mode~='visual' and mode~='audio' then return false,'invalid_mode' end
    local targets, seen = {}, {}
    for id in csv:gmatch('[^,]+') do
        local player = tonumber(id)
        if not player or player<1 or player>9007199254740991 or seen[player] then return false,'invalid_targets' end
        seen[player]=true; targets[#targets+1]=player
        if #targets>32 then return false,'target_limit' end
    end
    -- Check every target before allocating; native projection is still a separate gate.
    local roster = {}
    for _, player in ipairs(Open77.players.all()) do roster[tonumber(player)]=true end
    for _, player in ipairs(targets) do
        if not roster[player] or not Open77.ready.isReady(player) then return false,'target_not_ready:'..player end
    end
    local effect = args[6] or 'fire.small'
    local sound = mode=='audio' and (args[7] or 'w_cyb_strongarms_spy_perk_charge') or nil
    if #effect>512 or (sound and #sound>128) then return false,'invalid_name' end
    local value = {issuer=tonumber(issuer),targets=targets,ids={},accepted=0,rejected=0,errors={},expires=GetGameTimer()+ttl}
    batch=value
    for _, player in ipairs(targets) do
        local ok,id,reason = pcall(Open77.effects.attach,{kind='player',id=tostring(player)},effect,
            {slot='RightHand',localAnchor='body',ttlMs=ttl,soundEvent=sound,soundOnOwner=true,
                streamingRadius=90,streamingHysteresis=20})
        if ok and id then value.ids[#value.ids+1]=id; value.accepted=value.accepted+1
        else value.rejected=value.rejected+1; value.errors[#value.errors+1]={player=player,reason=tostring(ok and reason or id)} end
    end
    CreateThread(function()
        while batch==value and GetGameTimer()<value.expires do Wait(250) end
        if batch==value then cancel('expired') end
    end)
    local summary=report(value)
    print('[cyberware load] started '..summary)
    return true,summary
end
AddEventHandler('onPlayerDisconnected',function(player)
    player=tonumber(player)
    if not batch then return end
    if batch.issuer==player then cancel('issuer_disconnected'); return end
    for _, target in ipairs(batch.targets) do if target==player then cancel('target_disconnected'); return end end
end)
AddEventHandler('onResourceStop',function(name)
    if name~=GetCurrentResourceName() then return end
    stopping=true; cancel('resource_stop')
end)
