local OWNER=GetCurrentResourceName()
local props={}
local function reply(player,token,ok,reason)
    TriggerClientEvent('gizmoEditor:result',player,token,ok,reason or 'ok')
    print(('GIZMO EDITOR player=%s success=%s reason=%s'):format(player,tostring(ok),tostring(reason or 'ok')))
end
local authority=GizmoEditorAuthority.new({
    owner=OWNER,generation=GetCurrentResourceGeneration(),now=Open77.time.monotonic,
    get=Open77.props.get, apply=Open77.props.setTransform,
    actor=function(player)
        local p=Open77.players.get(player)
        if not p then return nil end
        local life=Open77.players.getLifeState(player)
        return {identity=p.userId,ready=p.ready,fresh=p.fresh,position=p.position,bucket=p.bucket,
            alive=type(life)=='table' and life.phase=='alive',
            allowed=Open77.acl.isAllowed(player,'command.gizmo.editor')==true}
    end,
    closed=function(player,token,why) reply(player,token,false,why) end,
})
RegisterCommand('gizmo.editor',function(player,args)
    if not player or player<=0 then return end
    if args[1]=='clear' then
        authority.drop(player)
        if props[player] then Open77.props.remove(props[player]); props[player]=nil end
        return TriggerClientEvent('gizmoEditor:close',player)
    end
    -- This example only edits its own test chair. Never borrow another
    -- resource's props by accepting an arbitrary client-supplied identifier.
    if not props[player] or not Open77.props.get(props[player]) then
        local p=Open77.players.get(player)
        if not p or not p.ready or not p.fresh or not p.position then return reply(player,'',false,'player_not_ready') end
        local why
        props[player],why=Open77.props.create({model='furniture.chair.metal',
            position={x=p.position.x+2,y=p.position.y+2,z=p.position.z},bucket=p.bucket,yaw=0})
        if not props[player] then return reply(player,'',false,why) end
    end
    local ticket,why=authority.open(player,props[player])
    if not ticket then return reply(player,'',false,why) end
    TriggerClientEvent('gizmoEditor:open',player,ticket)
end,true)
RegisterNetEvent('gizmoEditor:commit',function(token,transform)
    local player=tonumber(source)
    if not player or player<=0 then return end
    local ok,why=authority.commit(player,token,transform)
    reply(player,type(token)=='string' and token:sub(1,80) or '',ok,why)
end)
RegisterNetEvent('gizmoEditor:cancel',function(token)
    local player=tonumber(source)
    if player and player>0 then authority.cancel(player,token) end
end)
AddEventHandler('playerDropped',function()
    local player=tonumber(source)
    if not player then return end
    authority.drop(player)
    if props[player] then Open77.props.remove(props[player]);props[player]=nil end
end)
AddEventHandler('onResourceStop',function(name) if name==OWNER then authority.clear() end end)
CreateThread(function() while true do Wait(500);authority.tick() end end)
