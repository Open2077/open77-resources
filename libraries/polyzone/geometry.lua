-- PolyZone geometry, adapted from Michael Afrin's MIT PolyZone (see LICENSE).
-- Open77 vectors are ordinary {x,y,z} tables, not Cfx userdata.
local G = {}
function G.finite(v) return type(v) == 'number' and v == v and math.abs(v) < math.huge end
function G.vector(v, z)
    assert(type(v) == 'table' and G.finite(v.x or v[1]) and G.finite(v.y or v[2]), 'polyzone: expected finite position {x,y,z}')
    local result = {x = v.x or v[1], y = v.y or v[2], z = v.z or v[3] or z or 0}
    assert(G.finite(result.z), 'polyzone: invalid position.z')
    return result
end
function G.positive(v, name)
    assert(G.finite(v) and v > 0, 'polyzone: '..name..' must be positive and finite')
    return v
end
function G.copy(t) local out = {}; for k,v in pairs(t or {}) do out[k]=v end; return out end
function G.distance2(a,b,useZ)
    local z = useZ and ((a.z or 0) - (b.z or 0)) or 0
    return (a.x-b.x)^2 + (a.y-b.y)^2 + z*z
end
function G.rotate(origin, p, heading)
    local angle = math.rad(heading)
    local c,s,x,y = math.cos(angle),math.sin(angle),p.x-origin.x,p.y-origin.y
    return {x=origin.x+x*c-y*s,y=origin.y+x*s+y*c,z=p.z}
end
local function left(a,b,p) return (b.x-a.x)*(p.y-a.y)-(p.x-a.x)*(b.y-a.y) end
function G.winding(p,points)
    local winding = 0
    for i=1,#points do
        local a,b=points[i],points[i % #points+1]
        if a.y<=p.y then
            if b.y>p.y and left(a,b,p)>0 then winding=winding+1 end
        elseif b.y<=p.y and left(a,b,p)<0 then winding=winding-1 end
    end
    return winding~=0
end
function G.intersects(a,b,c,d)
    local ax,bx,dx,ay,by,dy=a.x-c.x,b.x-a.x,d.x-c.x,a.y-c.y,b.y-a.y,d.y-c.y
    local denominator=bx*dy-by*dx
    local n1,n2=ay*dx-ax*dy,ay*bx-ax*by
    if denominator==0 then return n1==0 and n2==0 end
    local r,s=n1/denominator,n2/denominator
    return r>=0 and r<=1 and s>=0 and s<=1
end
function G.bounds(points)
    local min,max={x=math.huge,y=math.huge},{x=-math.huge,y=-math.huge}
    local area=0
    for i,p in ipairs(points) do
        min.x,min.y=math.min(min.x,p.x),math.min(min.y,p.y)
        max.x,max.y=math.max(max.x,p.x),math.max(max.y,p.y)
        local q=points[i % #points+1]; area=area+p.x*q.y-q.x*p.y
    end
    return min,max,{x=max.x-min.x,y=max.y-min.y},{x=(min.x+max.x)/2,y=(min.y+max.y)/2,z=0},math.abs(area)*.5
end
function G.insideCell(zone,cx,cy)
    local x,y=zone.min.x+cx*zone.gridCellWidth,zone.min.y+cy*zone.gridCellHeight
    local cell={{x=x,y=y},{x=x+zone.gridCellWidth,y=y},{x=x+zone.gridCellWidth,y=y+zone.gridCellHeight},{x=x,y=y+zone.gridCellHeight}}
    local any=false
    for _,p in ipairs(cell) do if G.winding(p,zone.points) then any=true; break end end
    if not any then return false end
    for i=1,4 do for j=1,#zone.points do
        if G.intersects(cell[i],cell[i%4+1],zone.points[j],zone.points[j%#zone.points+1]) then return false end
    end end
    return true
end
function G.scaleOffset(options)
    local function expand(v,default)
        v=v or {default,default,default}
        assert(type(v)=='table' and (#v==3 or #v==6),'polyzone: scale/offset must contain 3 or 6 values')
        for _,n in ipairs(v) do assert(G.finite(n),'polyzone: scale/offset must be finite') end
        if #v==3 then return {v[1],v[1],v[2],v[2],v[3],v[3]} end
        return G.copy(v)
    end
    return expand(options.scale,1),expand(options.offset,0)
end
function G.transform(p,position,q)
    if not q then return {x=p.x+position.x,y=p.y+position.y,z=p.z+position.z} end
    local x,y,z,w=q.x or q.i or 0,q.y or q.j or 0,q.z or q.k or 0,q.w or q.r or 1
    local tx,ty,tz=2*(y*p.z-z*p.y),2*(z*p.x-x*p.z),2*(x*p.y-y*p.x)
    return {x=position.x+p.x+w*tx+y*tz-z*ty,y=position.y+p.y+w*ty+z*tx-x*tz,z=position.z+p.z+w*tz+x*ty-y*tx}
end
return G
