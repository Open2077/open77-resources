local PZ,loadError=require('@polyzone')
assert(PZ,'polyzone requires the Open77 dependency-module client update: '..tostring(loadError))
local draft,last,zone,page,ready,open,sourceText=nil,nil,nil,nil,false,false,''
local draftPreview=false
local function notice(text,ok)
    print('[polyzone] '..tostring(text))
    TriggerEvent('chat:addMessage',{author='PolyZone',text=tostring(text),color=ok and {34,216,226} or {255,180,90}})
    if page and ready then page:send('polyzone:notice',{text=tostring(text),ok=ok}) end
end
RegisterNetEvent('polyzone:notice',notice)
local function clone(value)
    if type(value)~='table' then return value end
    local result={};for k,v in pairs(value) do result[k]=clone(v) end;return result
end
local function update()
    if page and ready then page:send('polyzone:state',{open=open,draft=draft or false,source=sourceText}) end
end
local function redraw()
    if zone then zone:destroy(); zone=nil end
    if not draft then return end
    local options={name=draft.name,minZ=draft.minZ,maxZ=draft.maxZ,heading=draft.heading,debugPoly=true,useZ=draft.useZ}
    if draft.kind=='poly' and #draft.points>=3 then
        local ok,value=pcall(PZ.PolyZone.Create,PZ.PolyZone,draft.points,options)
        if ok then zone=value else notice('The polygon needs non-collinear points. Move sideways, then add a vertex.',false) end
    elseif draft.kind=='box' then zone=PZ.BoxZone:Create(draft.center,draft.length,draft.width,options)
    elseif draft.kind=='circle' then zone=PZ.CircleZone:Create(draft.center,draft.radius,options) end
    sourceText=zone and PZ.serialize(zone) or ''
    update()
    if draft.kind=='poly' and not draftPreview then
        draftPreview=true
        CreateThread(function()
            while draft and draft.kind=='poly' do
                local lines={}
                for i,p in ipairs(draft.points) do
                    local a={x=p.x,y=p.y,z=p.z+.05}
                    lines[#lines+1]={a=a,b={x=p.x,y=p.y,z=p.z+1},color='#19d5e0ff'}
                    local previous=draft.points[i-1]
                    if previous then lines[#lines+1]={a=a,b={x=previous.x,y=previous.y,z=previous.z+.05},color='#19d5e0ff'} end
                end
                Open77.debugDraw.set('polyzone:editor-draft',{lines=lines,ttl=.5,maxDistance=500})
                Wait(100)
            end
            Open77.debugDraw.clear('polyzone:editor-draft');draftPreview=false
        end)
    end
end
local function setOpen(value)
    if not page then
        local err;page,err=WebUI.create({entry='web/index.html',layer='menu',fps=30,transparent=true,visible=false})
        if not page then notice('Editor unavailable: '..tostring(err),false);return end
        page:on('polyzone:ready',function()ready=true;update()end)
        page:on('polyzone:action',function(payload)
            TriggerEvent('polyzone:editorAction',payload)
        end)
    end
    open=value
    if open then page:show() else page:hide() end
    page:setFocus(open,open)
    update()
end
local function command(name,args)
    args=args or {}
    if name=='pzcomboinfo' then TriggerEvent('polyzone:pzcomboinfo');return end
    if name=='pzedit' then setOpen(not open);return end
    if name=='pzcancel' then if zone then zone:destroy();zone=nil end;draft=nil;sourceText='';setOpen(false);return end
    if name=='pzlast' then
        if not last or last.kind=='poly' then return notice('/pzlast requires a previously finished box or circle.',false) end
        if draft then return notice('Finish or cancel the current zone first.',false) end
        local position=PZ.PolyZone.getPlayerPosition();if not position then return notice('Enter the world first.',false) end
        draft=clone(last)
        local heightDelta=position.z-draft.center.z
        if draft.minZ then draft.minZ=draft.minZ+heightDelta end
        if draft.maxZ then draft.maxZ=draft.maxZ+heightDelta end
        draft.center=position;if args[1] then draft.name=args[1] end
        redraw();setOpen(true);return
    end
    if name=='pzcreate' then
        if draft then return notice('Finish or cancel the current zone first.',false) end
        local position=PZ.PolyZone.getPlayerPosition()
        if not position then return notice('Enter the world before creating a zone.',false) end
        local kind=args[1] or 'poly'
        if kind~='poly' and kind~='box' and kind~='circle' then return notice('Usage: /pzcreate poly|box|circle [name] [length/radius] [width]',false) end
        draft={kind=kind,name=args[2] or 'new_zone',center=position,points={},heading=0,length=tonumber(args[3]) or 4,width=tonumber(args[4]) or 4,radius=tonumber(args[3]) or 3,useZ=false}
        if draft.length<=0 or draft.width<=0 or draft.radius<=0 then draft=nil;return notice('Dimensions must be positive.',false) end
        if kind=='poly' then draft.points[1]=clone(position) end
        redraw();setOpen(true);return
    end
    if not draft then return notice('Start a zone with /pzcreate first.',false) end
    if name=='pzadd' then
        if draft.kind~='poly' then return notice('/pzadd only applies to polygons.',false) end
        local p=PZ.PolyZone.getPlayerPosition();if not p then return end
        if #draft.points>=128 then return notice('Editor limit: 128 vertices.',false) end
        draft.points[#draft.points+1]=clone(p);redraw()
    elseif name=='pzundo' then table.remove(draft.points);redraw()
    elseif name=='pzfinish' then
        if not zone then return notice('Add at least three non-collinear polygon points.',false) end
        sourceText=PZ.serialize(zone)
        TriggerServerEvent('polyzone:save',sourceText)
        local stored,err=Open77.kvp.set('last_zone',sourceText)
        if not stored then notice('Local backup unavailable: '..tostring(err),false) end
        last=clone(draft);zone:destroy();zone=nil;draft=nil;update()
    end
end
RegisterNetEvent('polyzone:command',function(name,args)
    local ok,err=pcall(command,name,args);if not ok then notice(err,false) end
end)
AddEventHandler('polyzone:editorAction',function(payload)
    if type(payload)~='table' then return end
    local action=payload.action
    if action=='close' then setOpen(false);return end
    if action=='copy' then
        local ok,err=Open77.clipboard.setText(sourceText)
        notice(ok and 'Lua source copied.' or ('Copy failed: '..tostring(err)),ok);return
    end
    if action=='command' then
        local ok,err=pcall(command,payload.name,payload.args);if not ok then notice(err,false) end;return
    end
    if action=='moveHere' and draft then draft.center=PZ.PolyZone.getPlayerPosition() or draft.center;redraw();return end
    if action=='patch' and draft then
        local candidate=clone(draft)
        for _,key in ipairs({'length','width','radius','heading','minZ','maxZ'}) do
            if payload[key]~=nil then
                if payload[key]=='' and (key=='minZ' or key=='maxZ') then candidate[key]=nil
                else local n=tonumber(payload[key]);if not n or n~=n or math.abs(n)>100000 then return notice('Invalid '..key,false) end;candidate[key]=n end
            end
        end
        if candidate.length<=0 or candidate.width<=0 or candidate.radius<=0 then return notice('Dimensions must be positive.',false) end
        if candidate.minZ and candidate.maxZ and candidate.minZ>candidate.maxZ then return notice('minZ must not exceed maxZ.',false) end
        if type(payload.name)=='string' then candidate.name=payload.name:sub(1,96) end
        if type(payload.useZ)=='boolean' then candidate.useZ=payload.useZ end
        draft=candidate;local ok,err=pcall(redraw);if not ok then notice(err,false) end
    end
end)
AddEventHandler('onClientResourceStart',function(name)
    if name~=GetCurrentResourceName() then return end
    if not Open77.debugDraw or not Open77.world.entityGeometry then notice('Update the Open77 client to use native PolyZone geometry.',false) end
    RegisterKeyMapping('polyzone.editor','PolyZone: toggle editor focus','F9',function()if draft or page then setOpen(not open)end end)
    RegisterKeyMapping('polyzone.add','PolyZone: add polygon vertex','F10',function()
        if draft and draft.kind=='poly' then local ok,err=pcall(command,'pzadd');if not ok then notice(err,false)end end
    end)
end)
AddEventHandler('onClientResourceStop',function(name)
    if name~=GetCurrentResourceName() then return end
    if page then page:setFocus(false,false);page:destroy();page=nil end
end)
