local native, animations = Open77.playerInteractions, Open77.animations
local resource = Open77.resource.name()
local nonce = tostring(Open77.resource.generation())..':'..tostring(math.floor(Open77.time.monotonic()*1000))
local playing, running = {}, true
local defaults = { give={'give','give'}, heal={'examine','wounded'} }
local function message(text)
    TriggerEvent('chat:addMessage', {type='system',author='INTERACTIONS',text=text,color={0,229,255}})
end
-- The invited player's offer card: what is offered, a countdown and two rebindable keys (Y accept,
-- N decline, Pause -> Settings -> KEY BINDINGS). /interaction accept | decline still works.
local ACCEPT_ID, DECLINE_ID = 'open77_interactions_accept', 'open77_interactions_decline'
local KIND_TEXT = { give='Someone wants to give you something.', heal='Someone offers to treat you.',
    carry='Someone wants to carry you.', escort='Someone wants to escort you.', custom='Someone makes you an offer.' }
local card, cardShownAt = nil, -1
local function nowMs() return Open77.time.monotonic()*1000 end
local function keyFor(id, fallback)
    local ok, key = pcall(function() return Open77.input.keyFor(id) end)
    return (ok and type(key) == 'string' and key ~= '') and key or fallback
end
local function uikit(name, ...) pcall(Open77.exports.call, 'open77_uikit', name, ...) end
local function drawCard()
    if not card then return end
    local left = math.max(0, math.ceil((card.endsAt - nowMs())/1000))
    cardShownAt = left
    uikit('textUI', { text=card.text, eyebrow=('Offer - %d s'):format(left), position='center',
        actions={ {key=keyFor(ACCEPT_ID,'Y'), label='Accept'}, {key=keyFor(DECLINE_ID,'N'), label='Decline'} } })
end
local function hideCard(id)
    if card and (id == nil or card.id == id) then card=nil; cardShownAt=-1; uikit('hideTextUI') end
end
local function offerText(s)
    local options = type(s.options) == 'table' and s.options or {}
    local label = options.label or options.Label
    if type(label) == 'string' and label ~= '' then return label:sub(1, 120) end
    return KIND_TEXT[s.kind] or KIND_TEXT.custom
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
            local options = type(state.options) == 'table' and state.options or {}
            local invite = tonumber(options.inviteTimeoutMs or options.InviteTimeoutMs) or 15000
            card = { id=state.id, text=offerText(state), endsAt=nowMs()+invite }
            drawCard()
            message(('%s %s accept, %s decline (or /interaction accept | decline).'):format(card.text,
                keyFor(ACCEPT_ID,'Y'), keyFor(DECLINE_ID,'N')))
        elseif name=='onPlayerInteractionChanged' then
            local state=...
            if card and state and state.id == card.id and state.phase ~= 'offered' then hideCard(state.id) end
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
local function answer(accepted)
    if not card then return end
    local id = card.id
    hideCard(id)
    local _, err = controller.respond(id, accepted)
    if err then message(tostring(err)) end
end
pcall(Open77.input.registerKeyMapping, { id=ACCEPT_ID, name='Accept an offer from a player', key='Y',
    onPressed=function() answer(true) end })
pcall(Open77.input.registerKeyMapping, { id=DECLINE_ID, name='Decline an offer from a player', key='N',
    onPressed=function() answer(false) end })
AddEventHandler('onClientResourceStop',function(name)
    if name==resource then running=false; hideCard(); controller.shutdown() end
end)
CreateThread(function()
    while running do
        controller.tick(animations._context())
        if card then
            local left = math.ceil((card.endsAt - nowMs())/1000)
            if left <= 0 or not controller.get(card.id) then hideCard()
            elseif left ~= cardShownAt then drawCard() end
        end
        Wait(50)
    end
end)
