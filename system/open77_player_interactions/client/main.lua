local native, animations = Open77.playerInteractions, Open77.animations
local resource = Open77.resource.name()
local nonce = tostring(Open77.resource.generation())..':'..tostring(math.floor(Open77.time.monotonic()*1000))
local playing, running = {}, true
local defaults = { give={'give','give'}, heal={'examine','wounded'} }
local function message(text)
    TriggerEvent('chat:addMessage', {type='system',author='INTERACTIONS',text=text,color={0,229,255}})
end
local function stop(key)
    local p=playing[key]
    if p then for _, actor in pairs(p) do animations.stop(actor.entity) end end
    playing[key]=nil
    native._present(key)
end
local controller = PlayerInteractionController.new({
    now=function() return Open77.time.monotonic()*1000 end,
    send=function(name, ...) return TriggerServerEvent('open77:playerInteractions:'..name, ...) end,
    stop=stop,
    present=function(s, stage, context, changed)
        local status=native._present(s.id,s.kind,s.actor,s.target,stage=='active')
        if status ~= 'ok' then return status end
        local profiles=defaults[s.kind] or {}
        profiles={s.options.actorAnimation or profiles[1],s.options.targetAnimation or profiles[2]}
        local peers={tonumber(s.actor),tonumber(s.target)}
        playing[s.id]=playing[s.id] or {}
        local ready=true
        for index=1,2 do
            local profile=profiles[index]
            if profile then
                local entity=peers[index]==context.playerId and 0 or context.players[peers[index]]
                if entity == nil then return 'pending' end
                local old=playing[s.id][index]
                if old and old.entity ~= entity then animations.stop(old.entity); old=nil end
                if not old or old.stage ~= stage then
                    local ok,err=animations._playProfile(entity,profile,nil,stage=='active')
                    if not ok then return err or 'animation_failed' end
                    playing[s.id][index]={entity=entity,stage=stage,profile=profile}
                end
                local animationStatus=animations._profileStatus(entity)
                if animationStatus == 'device_pending' then ready=false
                elseif animationStatus ~= 'ok' then return animationStatus end
            end
        end
        return ready and 'ok' or 'pending'
    end,
    emit=function(name, ...)
        if name=='onPlayerInteractionOffered' then
            local state=...
            message(('Player %s requests %s. /interaction accept or /interaction decline'):format(state.actor,state.kind))
        elseif name=='onPlayerInteractionPresentationFailed' then
            local key,reason=...
            print(('Pair presentation failed: %s %s'):format(key,tostring(reason)))
            message('Interaction cancelled: '..tostring(reason))
        end
        TriggerEvent(name,...)
    end,
},nonce)
RegisterNetEvent('open77:playerInteractions:state',controller.receiveState)
RegisterNetEvent('open77:playerInteractions:snapshot',controller.receiveSnapshot)
RegisterNetEvent('open77:playerInteractions:result',controller.receiveResult)
RegisterNetEvent('open77_player_interactions:command',function(action)
    local current=controller.current()
    if not current then message('No active interaction.'); return end
    if action=='status' then message(current.kind..' · '..current.phase..' · '..current.id); return end
    local request,err
    if action=='cancel' then request,err=controller.cancel(current.id)
    elseif action=='accept' or action=='decline' then request,err=controller.respond(current.id,action=='accept') end
    if err then message(tostring(err)) end
end)
for _,method in ipairs({'list','get','current','isReserved','respond','cancel','result'}) do exports(method,controller[method]) end
exports('accept',function(id) return controller.respond(id,true) end)
exports('decline',function(id) return controller.respond(id,false) end)
AddEventHandler('onClientResourceStop',function(name)
    if name==resource then running=false; controller.shutdown() end
end)
CreateThread(function()
    while running do controller.tick(animations._context()); Wait(50) end
end)
