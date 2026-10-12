assert(load(CONTROLLER_SOURCE,'@pair-controller.lua'))()
local passed=0
local function test(name,run)
    local ok,err=pcall(run); assert(ok,name..': '..tostring(err)); passed=passed+1
end
local function fixture()
    local f={now=1000,sent={},events={},stops={},renders={},status='ok',
        context={ready=true,generation=1,bucket=0,playerId=2,players={[1]='101'}}}
    f.api=PlayerInteractionController.new({now=function() return f.now end,
        send=function(...) f.sent[#f.sent+1]={...}; return true end,
        emit=function(...) f.events[#f.events+1]={...} end,
        stop=function(key) f.stops[#f.stops+1]=key end,
        present=function(...) f.renders[#f.renders+1]={...}; return f.status end},'test')
    f.api.tick(f.context); f.sent={}
    return f
end
local function state(phase,revision,key)
    return {id=key or string.rep('b',32),epoch=string.rep('a',32),kind='give',actor='1',target='2',
        phase=phase or 'offered',revision=revision or 1,bucket=0,serverTimeMs=10000,startsAtMs=10500,endsAtMs=14500,options={}}
end
local function snapshot(f,states,revision)
    f.api.receiveSnapshot({snapshotId=string.rep('c',32),epoch=string.rep('a',32),bucket=0,
        revision=revision,slice=1,total=1,states=states,serverTimeMs=10000})
end
test('invitation does not lock or animate before consent',function()
    local f=fixture(); local s=state(); f.api.receiveState(s); f.api.tick(f.context)
    assert(#f.renders==0 and f.api.isReserved(1) and f.api.isReserved(2))
    assert(f.api.respond(s.id,true)); assert(f.sent[1][1]=='accept' and f.sent[1][3]==s.id)
    f.context.playerId=1; assert(not f.api.respond(s.id,true))
end)
test('two-phase preparation and clock-aligned start',function()
    local f=fixture(); f.api.receiveState(state('preparing',2)); f.api.tick(f.context)
    assert(f.sent[1][1]=='ready' and f.sent[1][4]==2 and f.sent[1][5]==true)
    f.api.tick(f.context); assert(#f.sent==1)
    f.api.receiveState(state('scheduled',3)); f.api.tick(f.context)
    assert(f.renders[#f.renders][2]=='preparing')
    f.now=f.now+500; f.api.tick(f.context); assert(f.renders[#f.renders][2]=='active')
end)
test('native failure cancels once and does not keep acknowledging',function()
    local f=fixture(); f.status='bone_unavailable'; f.api.receiveState(state('preparing',2)); f.api.tick(f.context)
    f.api.tick(f.context); assert(#f.sent==1 and f.sent[1][5]==false)
    assert(#f.stops==1 and #f.renders==1, 'failed presentation must stop immediately, not keep mounting')
end)

test('shared deadline releases native state without a terminal packet',function()
    local f=fixture(); f.api.receiveState(state('active',3)); f.api.tick(f.context)
    f.now=5500; f.api.tick(f.context); f.api.tick(f.context)
    assert(#f.stops==1 and #f.renders==1)
    for _,event in ipairs(f.events) do assert(event[1]~='onPlayerInteractionCompleted') end
end)
test('observer failures stop locally without cancelling other players',function()
    local f=fixture(); f.context.playerId=3; f.status='mount_unavailable'
    f.api.receiveState(state('active',3)); f.api.tick(f.context); f.api.tick(f.context)
    assert(#f.stops==1 and #f.renders==1 and #f.sent==0)
end)
test('terminal state releases both bodies and stale messages cannot revive',function()
    local f=fixture(); f.api.receiveState(state('active',3)); f.api.tick(f.context)
    f.api.receiveState(state('cancelled',4)); f.api.receiveState(state('active',3)); f.api.receiveState(state('cancelled',4))
    assert(#f.stops==1 and #f.api.list()==0)
end)
test('complete snapshot absence repairs missed cancellation',function()
    local f=fixture(); f.api.receiveState(state('preparing',2)); f.api.tick(f.context)
    snapshot(f,{},3); assert(#f.stops==1 and #f.api.list()==0)
    f.api.receiveState(state('active',2)); assert(#f.api.list()==0)
end)
test('old snapshot does not overwrite a newer live state',function()
    local f=fixture(); f.api.receiveState(state('active',4)); snapshot(f,{state('preparing',2)},3)
    assert(f.api.current().phase=='active')
end)
test('world/generation/bucket loss releases presentation',function()
    local f=fixture(); f.api.receiveState(state('preparing',2)); f.api.tick(f.context)
    f.api.tick({ready=true,generation=1,bucket=3,playerId=2,players={}})
    assert(#f.stops==1 and #f.api.list()==0)
    f.api.receiveState(state()); assert(#f.api.list()==0)
    f.api.shutdown(); assert(#f.stops==1)
end)
test('malformed peer ids, clocks and revisions are ignored',function()
    local f=fixture(); local s=state(); s.serverTimeMs=0/0; f.api.receiveState(s)
    s=state(); s.actor='garbage'; f.api.receiveState(s)
    s=state(); s.revision=-1; f.api.receiveState(s); assert(#f.api.list()==0)
end)
print(('player interaction client: %d tests passed'):format(passed))
