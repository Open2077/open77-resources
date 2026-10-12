local G=assert(require('@polyzone/geometry'))
local D={}
local function color(rgb,alpha)
    rgb=rgb or {0,255,0}
    return string.format('#%02x%02x%02x%02x',math.floor(math.max(0,math.min(255,rgb[1]))),
        math.floor(math.max(0,math.min(255,rgb[2]))),math.floor(math.max(0,math.min(255,rgb[3]))),alpha)
end
function D.build(zone,player)
    local result={lines={},triangles={},maxDistance=zone._options.debugDistance or 250,ttl=0.5}
    local outline=color(zone.debugColors.outline or {255,0,0},184)
    local wall=color(zone.debugColors.walls or zone.debugColor,48)
    local function line(a,b,c) result.lines[#result.lines+1]={a=a,b=b,color=c or outline} end
    local function triangle(a,b,c) result.triangles[#result.triangles+1]={a=a,b=b,c=c,color=wall} end
    local z=player and player.z or zone.center.z or 0
    local low,high=zone.minZ or z-45,zone.maxZ or z+45
    local points=zone.points
    if zone.isCircleZone then
        points={}; local count=48
        for i=0,count-1 do
            local angle=i*math.pi*2/count
            points[#points+1]={x=zone.center.x+zone.radius*math.cos(angle),y=zone.center.y+zone.radius*math.sin(angle)}
        end
        outline=color(zone.debugColor,190)
        if zone.useZ then
            for axis=1,3 do
                local last
                for i=0,count do
                    local angle=i*math.pi*2/count
                    local a,b=zone.radius*math.cos(angle),zone.radius*math.sin(angle)
                    local p={x=zone.center.x+(axis==3 and 0 or a),y=zone.center.y+(axis==1 and b or axis==3 and a or 0),z=zone.center.z+(axis~=1 and b or 0)}
                    if last then line(last,p,outline) end; last=p
                end
            end
            return result
        end
    end
    for i,p in ipairs(points) do
        local q=points[i%#points+1]
        if not zone.isCircleZone then p,q=zone:TransformPoint(p),zone:TransformPoint(q) end
        local a,b,c,d={x=p.x,y=p.y,z=low},{x=p.x,y=p.y,z=high},{x=q.x,y=q.y,z=low},{x=q.x,y=q.y,z=high}
        line(a,b);line(b,d);line(a,c);triangle(a,b,c);triangle(b,d,c)
    end
    if zone.debugGrid and zone.grid and zone.gridCellWidth then
        local gridColor=color(zone.debugColors.grid or {255,255,255},196)
        for y,row in pairs(zone.grid) do for x,inside in pairs(row) do
            if inside and #result.lines<=500 then
                local a={x=zone.min.x+x*zone.gridCellWidth,y=zone.min.y+y*zone.gridCellHeight,z=high}
                local b={x=a.x+zone.gridCellWidth,y=a.y,z=high}
                local c={x=b.x,y=b.y+zone.gridCellHeight,z=high}
                local d={x=a.x,y=c.y,z=high}
                line(a,b,gridColor);line(b,c,gridColor);line(c,d,gridColor);line(d,a,gridColor)
            end
        end end
    end
    return result
end
return D
