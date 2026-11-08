local page, running, serial, busy = nil, true, 0, false
local function await(promise) return promise:await() end
local function sendState(error)
    CreateThread(function()
        local state = await(Open77.animations.getIdle())
        if running and page then page:send('idle:state',{state=state or false,error=error}) end
    end)
end
local errors = {
    animset_not_found='Animation bank not found. Check the depot path and installed archives.',
    animset_load_failed='The game could not load this animation bank.',
    clip_not_found='This bank does not contain that clip. Check its exact name.',
    idle_owned_by_other_resource='A server resource currently controls your idle.',
    player_not_ready='Wait for your character to finish loading.',
}
local function message(reason) return errors[reason] or ('Idle unavailable: '..tostring(reason or 'unknown_error')) end
AddEventHandler('onClientResourceStart',function(name)
    if name~=GetCurrentResourceName() then return end
    page=FreeroamMenu.surface(); if not page then return end
    page:on('idle:action',function(p)
        if type(p)~='table' then return end
        if p.action=='state' then if not busy then sendState() end; return end
        if p.action=='clips' then
            if type(p.bank)~='string' or #p.bank>512 or type(p.query)~='string' or #p.query>128 or
                type(p.offset)~='number' or p.offset<0 or p.offset~=math.floor(p.offset) or type(p.request)~='number' then return end
            serial=serial+1; local current=serial
            CreateThread(function()
                local deadline=Open77.time.monotonic()+8
                repeat
                    local bank,err=Open77.animations.idleClips(p.bank,p.query,p.offset,30)
                    if not running or serial~=current then return end
                    if not bank or bank.ready then
                        page:send('idle:clips',{request=p.request,bank=p.bank,total=bank and bank.total or 0,
                            clips=bank and bank.clips or {},error=err and message(err) or nil});return
                    end
                    Wait(100)
                until Open77.time.monotonic()>deadline
                if running and serial==current then page:send('idle:clips',{request=p.request,bank=p.bank,error='The bank took too long to load. Try again.'}) end
            end)
        elseif (p.action=='apply' or p.action=='reset') and not busy then
            busy=true
            CreateThread(function()
                local value,err
                if p.action=='reset' then value,err=await(Open77.animations.resetIdle())
                else value,err=await(Open77.animations.setIdle({animset=p.animset,clip=p.clip,blendMs=p.blendMs,delayMs=p.delayMs})) end
                busy=false
                if running then sendState(not value and message(err) or nil) end
            end)
        end
    end)
end)
AddEventHandler('onClientResourceStop',function(name) if name==GetCurrentResourceName() then running=false; serial=serial+1;page=nil end end)
