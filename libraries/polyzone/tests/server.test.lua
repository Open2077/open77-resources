local root=assert(arg[1]); local handlers,net,commands,exported,sent,writes={},{},{},{},{},{}
local allowed,clock=true,0
Open77={acl={isAllowed=function(id,permission)return allowed and id==7 and permission:sub(1,8)=='command.' end},
 time={monotonic=function()return clock end},io={append=function(path,text)writes[#writes+1]={path,text};return true end}}
function AddEventHandler(name,fn) handlers[name]=fn end
function RegisterNetEvent(name,fn) net[name]=fn end
function RegisterCommand(name,fn,restricted)assert(restricted);commands[name]=fn end
function TriggerClientEvent(name,player,...)sent[#sent+1]={name,player,...};return true end
function exports(name,fn)exported[name]=fn end
assert(loadfile(root..'/server/main.lua'))()
assert(net['PolyZone:TriggerZoneEvent']==nil and handlers['PolyZone:TriggerZoneEvent'])
assert(exported.TriggerZoneEvent('test:event',123));assert(sent[1][1]=='__PolyZone__:test:event' and sent[1][2]==-1 and sent[1][3]==123)
assert(not exported.TriggerZoneEvent('bad\nname'))
commands.pzcreate(7,{'box','garage'});assert(sent[#sent][1]=='polyzone:command' and sent[#sent][2]==7)
local before=#sent;allowed=false;commands.pzcreate(7,{});assert(#sent==before)
source=7;net['polyzone:save']('bad');assert(#writes==0)
allowed=true;source=8;net['polyzone:save']('bad');assert(#writes==0)
source=7;net['polyzone:save']('local zone = {}');assert(#writes==1 and writes[1][1]=='polyzone_created_zones.txt')
net['polyzone:save']('rate limited');assert(#writes==1)
clock=2;net['polyzone:save'](string.rep('x',32769));assert(#writes==1)
clock=4;net['polyzone:save']('a\0b');assert(#writes==1)
handlers.onPlayerDisconnected(7);net['polyzone:save']('second');assert(#writes==2)
net['chat:ready']();assert(sent[#sent][1]=='chat:addSuggestions' and #sent[#sent][3]==8)
print('polyzone-server: PASS (ACL, relay, size/rate limits, save scope)')
