-- Continuous engine FX follow the SAME clipped rectangle as server damage.
-- No cell-edge props are used while this descriptor is present. Geometry work
-- and native calls are cooperatively bounded; persistent instances are moved,
-- not restarted at every sample. An unavailable renderer leaves HUD guidance.
local S = { authoritative = false, live = 0, failure = nil }
CordonSweepEdge = S
local bounds, received, allowed, map, survey = nil, 0, {}, nil, {}
local participating, generation, scan, wanted = false, 0, nil, {}
local instances, cursor, nextScan = {}, nil, 0
local serverStyle=nil
local function now() return Open77.time.monotonic() * 1000 end
local function settings()
    return Config.cordon.edge.sweep or {}
end
local function rect() return bounds and Grid.sweepRect(bounds.sweep, now()-received) end
local function adopt(payload)
    if type(payload) ~= 'table' then return end
    local incoming=payload.sweep
    if bounds and type(incoming)=='table' then
        local old=bounds.sweep
        if (incoming.generation or 0)<(old.generation or 0) or
            (incoming.generation==old.generation and (incoming.revision or 0)<(old.revision or 0)) then return end
    end
    if type(payload.edgeStyle)=='string' then serverStyle=payload.edgeStyle end
    local g = payload.grid or payload
    if g.originX and g.originY then
        map = { origin={x=g.originX,y=g.originY,z=g.originZ or 0},
            blockMetres=g.blockMetres, cols=g.cols, rows=g.rows }
    end
    if type(payload.sweep) ~= 'table' then
        bounds=nil; S.authoritative=false; generation=generation+1; return
    end
    S.authoritative=true
    -- Refreshing the relative clock must not continuously cancel an in-flight
    -- scan. Its resulting sample positions are re-evaluated at draw time.
    if not bounds or bounds.sweep.generation ~= payload.sweep.generation or
        bounds.sweep.phaseIndex ~= payload.sweep.phaseIndex then
        generation=generation+1; scan=nil; wanted={}; nextScan=0
    end
    local stamp=now()
    if bounds and bounds.sweep.generation==incoming.generation and bounds.sweep.phaseIndex==incoming.phaseIndex then
        stamp=math.min(stamp,received+(bounds.sweep.startsInMs or 0)-(incoming.startsInMs or 0))
    end
    bounds=payload; received=stamp
end
AddEventHandler('cordon:bounds:local', adopt)
AddEventHandler('cordon:survey:local',function(p) if type(p)=='table' then survey=p end end)
AddEventHandler('cordon:state:local',function(p)
    if type(p)~='table' then return end
    if type(p.cordon)=='table' and type(p.cordon.edgeStyle)=='string' then serverStyle=p.cordon.edgeStyle end
    participating=p.participant==true and type(p.cordon)=='table' and p.cordon.active==true
    if not participating then
        bounds=nil;S.authoritative=false;generation=generation+1
    elseif type(p.cordon.sweep)=='table' then adopt(p.cordon) end
end)

local function oneCell(c,r,current)
    return Grid.sweepSegments(map,allowed,current,nil,{loCol=c,hiCol=c,loRow=r,hiRow=r})
end
local function position(sample,current,cache)
    -- A face can disappear when the moving rectangle passes its cell. Never
    -- leave an instance on an obsolete, now-internal edge awaiting a rescan.
    local col,row=sample.col,sample.row
    if sample.rim then
        if sample.side=='west' then col=math.floor((current.minX-map.origin.x)/map.blockMetres)+1
        elseif sample.side=='east' then col=math.ceil((current.maxX-map.origin.x)/map.blockMetres)
        elseif sample.side=='south' then row=math.floor((current.minY-map.origin.y)/map.blockMetres)+1
        else row=math.ceil((current.maxY-map.origin.y)/map.blockMetres) end
    end
    local key=Grid.key(col,row)
    local segments=cache and cache[key]
    if not segments then segments=oneCell(col,row,current);if cache then cache[key]=segments end end
    for _, segment in ipairs(segments) do
        if segment.side==sample.side then
            local z=survey.ground and tonumber(survey.ground[Grid.key(col,row)])
            local angle=math.atan(-segment.nx,segment.ny)+math.rad(settings().yawOffset or 0)
            return {x=segment.ax+(segment.bx-segment.ax)*sample.t,
                y=segment.ay+(segment.by-segment.ay)*sample.t,
                z=(z or tonumber(survey.groundDefault) or map.origin.z)+(settings().heightOffset or 0)},
                {x=0,y=0,z=math.sin(angle*.5),w=math.cos(angle*.5)}
        end
    end
end
local function beginScan(here)
    local stamp, descriptor = generation, bounds
    local job={}
    scan=job
    CreateThread(function()
        local ok,why=pcall(function()
        local indexed={}
        for i,key in ipairs(descriptor.allowed or {}) do
            indexed[key]=true
            if i%8==0 then Wait(0) end
        end
        if stamp~=generation or scan~=job then return end
        allowed=indexed
        local cfg=settings()
        local radius=math.max(10,math.min(350,cfg.radius or 100))
        local spacing=math.max(2,cfg.spacing or 4)
        local maximum=math.max(1,math.min(96,cfg.maxInstances or 48))
        local candidates={}
        local c0=math.floor((here.x-map.origin.x)/map.blockMetres)+1
        local r0=math.floor((here.y-map.origin.y)/map.blockMetres)+1
        local reach=math.ceil(radius/map.blockMetres)+1
        for c=math.max(1,c0-reach),math.min(map.cols,c0+reach) do
            for r=math.max(1,r0-reach),math.min(map.rows,r0+reach) do
                if stamp~=generation or scan~=job then return end
                local current=rect()
                for _,segment in ipairs(oneCell(c,r,current)) do
                    local length=math.abs(segment.bx-segment.ax)+math.abs(segment.by-segment.ay)
                    local count=math.max(1,math.ceil(length/spacing))
                    local rim=(segment.side=='west' and segment.ax==current.minX) or
                        (segment.side=='east' and segment.ax==current.maxX) or
                        (segment.side=='south' and segment.ay==current.minY) or
                        (segment.side=='north' and segment.ay==current.maxY)
                    local face=rim and ('rim:'..segment.side..':'..((segment.nx~=0) and r or c)) or
                        ('cell:'..c..','..r..':'..segment.side)
                    for i=1,count do
                        local t=(i-.5)/count
                        local x,y=segment.ax+(segment.bx-segment.ax)*t,segment.ay+(segment.by-segment.ay)*t
                        local distance=(x-here.x)^2+(y-here.y)^2
                        if distance<=radius^2 then
                            local entry={col=c,row=r,side=segment.side,t=t,distance=distance,rim=rim,
                                key=face..':'..i}
                            local at=#candidates+1
                            while at>1 and candidates[at-1].distance>distance do at=at-1 end
                            if at<=maximum then
                                table.insert(candidates,at,entry)
                                if #candidates>maximum then table.remove(candidates) end
                            end
                        end
                        Wait(0)
                    end
                end
                Wait(0)
            end
        end
        local result={}
        for _,sample in ipairs(candidates) do result[sample.key]=sample; Wait(0) end
        if stamp==generation and scan==job then
            wanted=result
            if cfg.diagnostics then
                print(('[cordon sweep] planned=%d live=%d effect=%s failure=%s'):format(
                    #candidates,S.live,tostring(cfg.effect),tostring(S.failure)))
            end
        end
        end)
        if not ok then S.failure=tostring(why);print("[cordon sweep scan] "..S.failure) end
        if scan==job then scan=nil end
    end)
end
local function retire(key)
    local item=instances[key]
    if item then Open77.vfx.stop(item.id);instances[key]=nil;S.live=S.live-1 end
end
local function run()
    while true do
        local cfg=settings()
        local available=type(Open77.vfx)=='table' and type(Open77.vfx.update)=='function'
        local style=serverStyle or Config.cordon.edge.style or Config.cordon.edgeStyle or 'hud'
        local active=S.authoritative and participating and map and cfg.enabled==true and available and style=='world'
        local current=active and rect() or nil
        if not current then
            local key=next(instances)
            if key then retire(key) end
            wanted={}; scan=nil; cursor=nil;nextScan=0
            Wait(0)
        else
            if not scan and now()>=nextScan then
                local me=Open77.character.state()
                if me and me.position then beginScan(me.position) end
                nextScan=now()+250
            end
            -- Cache cells shared by adjacent panels. Four updates keep the
            -- actual sandbox's 80us Lua budget bounded; 24 panels get ~10Hz.
            local frameCells={}
            for work=1,math.max(1,math.min(4,cfg.updatesPerFrame or 4)) do
                local key,item=next(instances,cursor)
                if not key then cursor=nil;break end
                cursor=key
                local sample=wanted[key]
                local p,orientation
                if sample then p,orientation=position(sample,current,frameCells) end
                if not p then retire(key);cursor=nil
                else
                    local ok,why=Open77.vfx.update(item.id,{position=p,orientation=orientation})
                    if not ok then S.failure=tostring(why);retire(key);cursor=nil end
                end
            end
            if S.live<math.min(96,cfg.maxInstances or 48) then
                for candidate,sample in pairs(wanted) do
                    if not instances[candidate] then
                        local p,orientation=position(sample,current,frameCells)
                        if p then
                            local id,why=Open77.vfx.play(cfg.effect or 'fire.large',{position=p,orientation=orientation,duration=0})
                            if id then instances[candidate]={id=id};S.live=S.live+1
                            else S.failure=tostring(why) end
                        end
                        break
                    end
                end
            end
            Wait(0)
        end
    end
end
CreateThread(function()
    while true do
        local ok,why=pcall(run)
        if not ok then
            S.failure=tostring(why)
            print('[cordon sweep] '..S.failure)
            -- A thread exception must not leave a misleading frozen boundary.
            wanted={};scan=nil;cursor=nil
            while next(instances) do retire(next(instances));Wait(0) end
            Wait(1000)
        end
    end
end)
