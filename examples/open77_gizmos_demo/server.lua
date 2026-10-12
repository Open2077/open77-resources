-- Install only on a development server. The platform's restricted-command
-- dispatcher checks command.gizmo.demo against the authenticated sender's ACL.
-- No client-supplied player ID is accepted and no authoritative entity is moved.
local actions = {
    virtual=true, localProp=true, target=true, targetData=true, state=true, set=true,
    mode=true, space=true, undo=true, redo=true, commit=true, cancel=true,
    activate=true, clear=true,
}

RegisterCommand('gizmo.demo', function(player, args, raw)
    if not player or player <= 0 then return print('gizmo.demo requires a connected player') end
    if not actions[args[1]] or #args > 4 then
        return TriggerClientEvent('open77:command:result', player, raw, false,
            'Usage: /gizmo.demo virtual|localProp|target <kind> <id>|state|set <x> <y> <z>|mode|space|undo|redo|commit|cancel|activate|clear')
    end
    if args[1] == 'state' then
        local read = Open77.players.get(player)
        print('GIZMO server-state '..json.encode({
            player=player, ready=read and read.ready, position=Open77.players.position(player),
        }))
        -- Independent authority read for preview-isolation tests. Do not log
        -- model internals or accept mutable state from the client here.
        for _,v in ipairs(Open77.vehicles.all(read and read.bucket or 0)) do
            print('GIZMO server-vehicle '..json.encode({id=v.id,owner=v.physicsOwner,
                epoch=v.authorityEpoch,position={x=v.x,y=v.y,z=v.z}}))
        end
    end
    TriggerClientEvent('gizmos:demo:run', player, table.unpack(args))
end, true)

-- Authoritative placement laboratory, confined to one disposable car created
-- by this resource per admin. It never accepts an arbitrary entity id or pose.
local cars={}
local targets={npc={},prop={}}
-- Fixed-pose NPC/prop authority tests. This command can touch only disposable
-- entities it created for this authenticated admin, in the same routing bucket.
RegisterCommand('gizmo.target',function(player,args,raw)
    if not player or player<=0 then return end
    local kind,action=args[1],args[2]
    local entries=targets[kind]
    local function reply(ok,why)
        TriggerClientEvent('open77:command:result',player,raw,ok,why)
        print('GIZMO target-lab '..json.encode({player=player,kind=kind,ok=ok,reason=why}))
    end
    if not entries or #args~=2 then return reply(false,'npc|prop spawn|place|nudge|turn|state|clear') end
    local api=kind=='npc' and Open77.npcs or Open77.props
    local entry=entries[player]
    if action=='clear' then
        if entry then api.remove(entry.id);entries[player]=nil end
        return reply(true,'cleared')
    end
    local actor=Open77.players.get(player)
    if not actor or not actor.ready or not actor.fresh or not actor.position then return reply(false,'player_not_ready') end
    if action=='spawn' then
        if entry then api.remove(entry.id);entries[player]=nil end
        local p=actor.position
        local origin={x=p.x+3,y=p.y+2,z=p.z}
        local options={position=origin,bucket=actor.bucket,yaw=0}
        if kind=='npc' then
            options.record='Character.cpz_maelstrom_grunt1_ranged1_lexington_wa'
            options.aiMode=Open77.npcs.ai.tasks
            options.damagePolicy=Open77.npcs.damage.immortal
            options.behavior={combatEnabled=false,perceptionEnabled=false,voiceEnabled=false}
        else options.model='furniture.chair.metal' end
        local id,why=api.create(options)
        if not id then return reply(false,tostring(why)) end
        entries[player]={id=id,origin=origin,bucket=actor.bucket}
        return reply(true,'created '..tostring(id))
    end
    if not entry or actor.bucket~=entry.bucket or not api.get(entry.id) then return reply(false,'spawn a laboratory target first') end
    if action=='place' or action=='nudge' or action=='turn' then
        local p=entry.origin
        local offset=action=='place' and 2 or .25
        local yaw=action=='turn' and 180 or 90
        return reply(api.setTransform(entry.id,{position={x=p.x+offset,y=p.y,z=p.z},yaw=yaw}),'server placement '..tostring(entry.id))
    end
    if action=='state' then
        local target=api.get(entry.id)
        print('GIZMO server-target '..json.encode(target))
        return reply(true,'state '..tostring(entry.id))
    end
    return reply(false,'npc|prop spawn|place|nudge|turn|state|clear')
end,true)
RegisterCommand('gizmo.vehicle',function(player,args,raw)
    if not player or player<=0 then return end
    local actor=Open77.players.get(player)
    local function reply(ok,why)
        TriggerClientEvent('open77:command:result',player,raw,ok,why)
        print('GIZMO vehicle-lab '..json.encode({player=player,ok=ok,reason=why}))
    end
    if args[1]=='clear' then
        if cars[player] then Open77.vehicles.remove(cars[player].id);cars[player]=nil end
        return reply(true,'cleared')
    end
    if not actor or not actor.ready or not actor.fresh or not actor.position then return reply(false,'player_not_ready') end
    if args[1]=='spawn' then
        if cars[player] then Open77.vehicles.remove(cars[player].id);cars[player]=nil end
        local p=actor.position
        local position={x=p.x+4,y=p.y,z=p.z+.25}
        local id,why=Open77.vehicles.create({record='Vehicle.v_standard2_archer_hella_player',position=position,bucket=actor.bucket})
        if not id then return reply(false,tostring(why)) end
        cars[player]={id=id,origin=position,bucket=actor.bucket}
        return reply(true,'created '..tostring(id))
    end
    local car=cars[player]
    if not car or not Open77.vehicles.get(car.id) then return reply(false,'spawn a laboratory vehicle first') end
    if actor.bucket~=car.bucket then return reply(false,'laboratory vehicle is in another bucket') end
    if args[1]=='board' or args[1]=='leave' then
        local npc=targets.npc[player]
        if not npc or npc.bucket~=car.bucket or not Open77.npcs.get(npc.id) then return reply(false,'spawn a laboratory NPC first') end
        local task,why
        if args[1]=='board' then
            task,why=Open77.npcs.tasks.enterVehicle(npc.id,car.id,'driver',{warp=true})
        else task,why=Open77.npcs.tasks.exitVehicle(npc.id) end
        return reply(task~=nil,task and ('occupant task '..tostring(task)) or tostring(why))
    end
    if args[1]~='place' and args[1]~='placeAfterCommit' then return reply(false,'spawn | place | placeAfterCommit | board | leave | clear') end
    local function place()
        local current=Open77.players.get(player)
        if cars[player]~=car or not current or not current.ready or not current.fresh or current.bucket~=car.bucket then return end
        local p=car.origin
        local ok=Open77.vehicles.setTransform(car.id,{position={x=p.x+2,y=p.y,z=p.z},yaw=90})
        reply(ok,'server placement '..tostring(car.id))
    end
    if args[1]=='placeAfterCommit' then
        TriggerClientEvent('gizmos:demo:run',player,'commit')
        SetTimeout(100,place)
    else place() end
end,true)
AddEventHandler('playerDropped',function()
    local player=tonumber(source)
    if cars[player] then Open77.vehicles.remove(cars[player].id);cars[player]=nil end
    for kind,entries in pairs(targets) do
        if entries[player] then
            local api=kind=='npc' and Open77.npcs or Open77.props
            api.remove(entries[player].id);entries[player]=nil
        end
    end
end)
