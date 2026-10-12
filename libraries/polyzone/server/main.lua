local function allowed(player,command)
    return player and player>0 and Open77.acl and Open77.acl.isAllowed(player,'command.'..command)==true
end
local function reply(player,text,ok)
    TriggerClientEvent('polyzone:notice',player,tostring(text),ok==true)
end
local commands={'pzcreate','pzadd','pzundo','pzfinish','pzlast','pzcancel','pzcomboinfo','pzedit'}
for _,command in ipairs(commands) do
    RegisterCommand(command,function(player,args)
        if not allowed(player,command) then return end
        TriggerClientEvent('polyzone:command',player,command,args)
    end,true)
end
local function triggerZoneEvent(name,...)
    if type(name)~='string' or #name==0 or #name>100 or name:find('[%c]') then return false,'invalid_event_name' end
    return TriggerClientEvent('__PolyZone__:'..name,-1,...)
end
exports('TriggerZoneEvent',triggerZoneEvent)
-- Local/server invocation only. Do not turn this into an arbitrary
-- client-controlled broadcast relay as the original FiveM resource did.
AddEventHandler('PolyZone:TriggerZoneEvent',triggerZoneEvent)
local lastSave={}
RegisterNetEvent('polyzone:save',function(text)
    local player=source
    if not allowed(player,'pzfinish') then return end
    local time=Open77.time.monotonic()
    if lastSave[player] and time-lastSave[player]<1 then return end
    lastSave[player]=time
    if type(text)~='string' or #text>32768 or #text==0 or text:find('\0',1,true) then return reply(player,'Invalid or oversized zone source.',false) end
    local ok,err=Open77.io.append('polyzone_created_zones.txt','\n-- Zone editor export\n'..text)
    reply(player,ok and 'Saved to polyzone/data/polyzone_created_zones.txt' or ('Save failed: '..tostring(err)),ok)
end)
AddEventHandler('onPlayerDisconnected',function(id) lastSave[tonumber(id)]=nil end)
RegisterNetEvent('chat:ready',function()
    local suggestions={}
    for _,command in ipairs(commands) do
        if allowed(source,command) then suggestions[#suggestions+1]={command='/'..command,help='PolyZone editor: '..command,parameters={}} end
    end
    TriggerClientEvent('chat:addSuggestions',source,suggestions)
end)
