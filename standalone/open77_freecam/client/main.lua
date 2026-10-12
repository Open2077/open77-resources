local C, P, I = Open77.camera, Open77.players, Open77.input
local config = FreecamConfig
local current, page
local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end
local function copy(p) return {x=p.x, y=p.y, z=p.z} end
local function length(p) return math.sqrt(p.x*p.x+p.y*p.y+p.z*p.z) end
local function report(text)
    print('[open77_freecam] '..text)
    TriggerEvent('chat:addMessage', {type='system', author='FREECAM', text=text})
end
local function publish()
    if page then page:send('freecam:state', current and {
        phase=current.phase, speed=current.speed, fov=current.fov, distance=current.distance or 0,
        limit=current.limit, keys=current.keys,
    } or {phase='off'}) end
end
local function stop(reason)
    local old = current
    if not old then return true end
    current = nil
    if old.camera then
        -- Destroying also releases a camera while its full body is preparing.
        C.destroy(old.camera)
    end
    P.resetControls() -- releases only this package's blocks
    publish()
    TriggerEvent('open77:freecam:stopped', reason or 'closed')
    return true
end
local function keys()
    local result = {}
    for name, fallback in pairs(config.keys) do
        result[name] = I.keyFor('freecam.'..name) or fallback
    end
    return result
end
local function resetShot(s)
    local character = Open77.character.state()
    if not character or not character.alive then return false end
    local p, f = character.position, s.initialForward
    s.position = {x=p.x-f.x*4, y=p.y-f.y*4, z=p.z+2.1}
    s.yaw = math.deg(math.atan(-f.x, f.y))
    s.pitch = -5
    s.fov = s.initialFov
    return true
end
local function start()
    if current then return false, 'freecam_already_active' end
    if I.isCaptured() or Open77.session.isMenuOpen() then return false, 'close_other_menu' end
    local character = Open77.character.state()
    if not character or not character.attached or not character.alive then return false, 'player_not_ready' end
    if P.isInVehicle() ~= false then return false, 'leave_vehicle_first' end
    local view = C.view()
    if not view then return false, 'camera_unavailable' end
    local s = {phase='preparing', owner=GetInvokingResource(), generation=GetInvokingResourceGeneration(), keys=keys(),
        speed=clamp(config.speed, .25, 40), limit=clamp(config.maxDistance, 5, 200),
        initialForward=copy(view.forward), initialFov=clamp(view.fov, 15, 110)}
    if not resetShot(s) then return false, 'player_not_ready' end
    local reason
    s.camera, reason = C.create({position=s.position, rotation={yaw=s.yaw,pitch=s.pitch},
        fov=s.fov, thirdPersonBody=true})
    if not s.camera then return false, reason end
    -- Older clients ignore unknown create options: fail visibly, never show a
    -- headless body while pretending the full-body contract was understood.
    local supported = false
    for _, item in ipairs((C.cameras() or {}).cameras or {}) do
        if item.id == s.camera and item.thirdPersonBody == true then supported = true end
    end
    if not supported then C.destroy(s.camera); return false, 'updated_freecam_client_required' end
    current = s
    for _, block in ipairs({{P.freezePosition,true}, {P.freezeRotation,true},
        {P.allowJump,false}, {P.allowAim,false}, {P.allowShoot,false},
        {P.allowWeapons,false}, {P.allowInteraction,false}, {P.allowDodge,false}}) do
        local ok, why = block[1](block[2])
        if not ok then stop(why); return false, why end
    end
    publish()
    CreateThread(function()
        local worked, failure = pcall(function()
        -- F7 / a previous activity may still be settling. Retry this named
        -- transient refusal only; never take another resource's view.
        local deadline, ok, pending = GetGameTimer()+2500, false, nil
        repeat
            if current ~= s then return end
            ok, pending = C.activate(s.camera, {blendMs=250})
            if ok or pending ~= 'camera_unavailable' then break end
            Wait(50)
        until GetGameTimer() >= deadline
        if not ok then stop(pending); report(tostring(pending)); return end
        if pending then
            local _, why = pending:await()
            if current ~= s then return end
            if why then stop(why); report(tostring(why)); return end
        end
        if current ~= s then return end
        s.phase = 'active'
        s.mouseX, s.mouseY, s.wheel = I.axis('mouseDeltaX') or 0, I.axis('mouseDeltaY') or 0, I.axis('mouseWheel') or 0
        s.clock = GetGameTimer()
        publish()
        TriggerEvent('open77:freecam:started')
        end)
        if not worked and current == s then stop('script_error'); report(tostring(failure)) end
    end)
    return true
end
local function update(s)
    -- Stop notifications are VM-local; a caller reload must not leave the
    -- provider holding its camera/control lease for an abandoned generation.
    if s.owner and s.owner~='' and (GetResourceState(s.owner)~='running' or
        Open77.resource.generation(s.owner)~=s.generation) then return stop('owner_stopped') end
    local registry = C.cameras()
    local character = Open77.character.state()
    if not character or not character.alive or not character.attached then return stop('player_unavailable') end
    if s.phase ~= 'active' then return end
    if not registry or not registry.held or registry.activeCamera ~= s.camera then return stop('camera_released') end
    local now = GetGameTimer()
    local dt = clamp((now-s.clock)/1000, 0, .05)
    s.clock = now
    local x,y,w = I.axis('mouseDeltaX') or s.mouseX, I.axis('mouseDeltaY') or s.mouseY, I.axis('mouseWheel') or s.wheel
    local dx,dy,dw = x-s.mouseX,y-s.mouseY,w-s.wheel
    s.mouseX,s.mouseY,s.wheel = x,y,w
    -- Discard accumulated mouse deltas while chat/pause has the focus.
    if I.isCaptured() or Open77.session.isMenuOpen() then return end
    s.keys = keys()
    local function down(name) return I.isDown(s.keys[name]) == true end
    if down('exit') then return stop('closed') end
    if down('reset') then resetShot(s) end
    s.yaw = (s.yaw-clamp(dx,-600,600)*config.sensitivity)%360
    s.pitch = clamp(s.pitch-clamp(dy,-600,600)*config.sensitivity,-85,85)
    if dw ~= 0 then
        if down('slow') then s.fov=clamp(s.fov-dw*2,15,110)
        else s.speed=clamp(s.speed*1.15^clamp(dw,-8,8),.25,40) end
    end
    local yaw,pitch = math.rad(s.yaw),math.rad(s.pitch)
    local f = {x=-math.sin(yaw)*math.cos(pitch), y=math.cos(yaw)*math.cos(pitch), z=math.sin(pitch)}
    local forward = (down('forward') and 1 or 0)-(down('back') and 1 or 0)
    local side = (down('right') and 1 or 0)-(down('left') and 1 or 0)
    local up = (down('up') and 1 or 0)-(down('down') and 1 or 0)
    local delta = {x=f.x*forward+math.cos(yaw)*side, y=f.y*forward+math.sin(yaw)*side, z=f.z*forward+up}
    local magnitude = math.max(1,length(delta))
    local speed = s.speed*(down('boost') and 4 or (down('slow') and .2 or 1))*dt/magnitude
    local nextPosition = {x=s.position.x+delta.x*speed,y=s.position.y+delta.y*speed,z=s.position.z+delta.z*speed}
    local p=character.position
    local offset={x=nextPosition.x-p.x,y=nextPosition.y-p.y,z=nextPosition.z-p.z}
    s.distance=length(offset)
    if s.distance > s.limit then
        local scale=s.limit/s.distance
        nextPosition={x=p.x+offset.x*scale,y=p.y+offset.y*scale,z=p.z+offset.z*scale}
        s.distance=s.limit
    end
    s.position=nextPosition
    local ok,why=C.setTransform(s.camera,{position=s.position,rotation={yaw=s.yaw,pitch=s.pitch},fov=s.fov})
    if not ok then stop(why); report(tostring(why)) end
end
local function snapshot()
    return {active=current~=nil, phase=current and current.phase or 'off',
        speed=current and current.speed or nil, fov=current and current.fov or nil,
        keys=keys(),
        position=current and copy(current.position) or nil, camera=C.cameras(), view=C.view(),
        character=Open77.character.state(), controls=P.getControlMask()}
end
exports('start',start)
exports('stop',function()
    local caller=GetInvokingResource()
    if current and (caller~=current.owner or GetInvokingResourceGeneration()~=current.generation) then
        return false,'freecam_owned_by_another_resource'
    end
    return stop('export')
end)
exports('state',snapshot)
RegisterNetEvent('open77:freecam:command',function(action)
    if action=='state' then return print('[open77_freecam] state '..json.encode(snapshot())) end
    if action=='off' or (action=='toggle' and current) then return stop('command') end
    local ok,why=start()
    if not ok then report(tostring(why)) end
end)
for name,key in pairs(config.keys) do
    RegisterKeyMapping('freecam.'..name,'Freecam: '..name,key,function()
        if name=='toggle' then
            if current then stop('key') else TriggerServerEvent('open77:command:execute','freecam','on') end
        end
    end)
end
AddEventHandler('onClientResourceStart',function(name)
    if name~=GetCurrentResourceName() then return end
    page=WebUI.create({entry='web/index.html',layer='hud',width=1920,height=1080,
        transparent=true,visible=true,fps=10,zIndex=950})
    if page then page:on('freecam:ready',publish) end
end)
AddEventHandler('onClientResourceStop',function(name)
    if name==GetCurrentResourceName() or (current and name==current.owner) then stop('resource_stopped') end
end)
CreateThread(function()
    local lastHud=0
    while true do
        Wait(current and 0 or 150)
        if current then
            local ok,why=pcall(update,current)
            if not ok then stop('script_error'); report(tostring(why)) end
            if GetGameTimer()-lastHud>=150 then lastHud=GetGameTimer();publish() end
        end
    end
end)
