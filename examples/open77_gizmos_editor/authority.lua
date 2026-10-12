-- Reusable policy example, with no client-trusted source/owner/revision.
-- api.actor/get/apply/now are synchronous server reads and writes. Do not yield
-- between the final revision check and apply in an adapter.
GizmoEditorAuthority = {}
local function finite(n)
    return type(n)=='number' and n==n and math.abs(n)<=1000000
end
local function fields(t, allowed)
    if type(t)~='table' then return false end
    for k in pairs(t) do if not allowed[k] then return false end end
    return true
end
local function vector(t)
    return fields(t,{x=true,y=true,z=true}) and finite(t.x) and finite(t.y) and finite(t.z)
end
local function distance(a,b)
    if not vector(a) or not vector(b) then return math.huge end
    return ((a.x-b.x)^2+(a.y-b.y)^2+(a.z-b.z)^2)^.5
end
function GizmoEditorAuthority.new(api)
    local sessions, locks, sequence = {}, {}, 0
    local S = {}
    local function release(player)
        local s=sessions[player]
        if s then locks[s.prop]=nil; sessions[player]=nil end
        return s
    end
    local function actor(player)
        local a=api.actor(player)
        if not a or not a.ready or not a.fresh or not a.alive or not vector(a.position)
            or type(a.identity)~='string' or a.identity=='' then return nil,'player_not_ready' end
        if not a.allowed then return nil,'permission_denied' end
        return a
    end
    local function target(id, a)
        local p=api.get(id)
        if not p then return nil,'target_missing' end
        if p.resource~=api.owner then return nil,'target_not_owned' end
        if p.attachment then return nil,'target_attached' end
        if p.bucket~=a.bucket then return nil,'wrong_bucket' end
        if distance(p.position,a.position)>25 then return nil,'too_far' end
        return p
    end
    local function validate(player,s)
        if api.now()>=s.expires then return nil,'ticket_expired' end
        local a,why=actor(player); if not a then return nil,why end
        if a.identity~=s.identity then return nil,'identity_changed' end
        if a.bucket~=s.bucket then return nil,'wrong_bucket' end
        local p; p,why=target(s.prop,a); if not p then return nil,why end
        if p.revision~=s.revision then return nil,'stale_revision' end
        return p,a
    end
    function S.open(player,id)
        if sessions[player] then return nil,'already_editing' end
        local a,why=actor(player); if not a then return nil,why end
        local p; p,why=target(id,a); if not p then return nil,why end
        if locks[id] then return nil,'target_busy' end
        sequence=sequence+1
        local s={token=tostring(api.generation)..':'..sequence,identity=a.identity,
            prop=id,revision=p.revision,bucket=a.bucket,expires=api.now()+120000,
            origin={x=p.position.x,y=p.position.y,z=p.position.z}}
        sessions[player]=s; locks[id]=player
        return {token=s.token,target={kind='prop',id=id},timeoutMs=120000}
    end
    function S.commit(player,token,t)
        local s=sessions[player]
        if not s or type(token)~='string' or token~=s.token then return false,'invalid_ticket' end
        -- One accepted ticket means one attempt, even if validation refuses it.
        release(player)
        local p,a=validate(player,s); if not p then return false,a end
        if not fields(t,{position=true,rotation=true,scale=true}) or not vector(t.position)
            or not fields(t.rotation,{x=true,y=true,z=true,w=true}) or not vector(t.scale) then
            return false,'invalid_transform'
        end
        local q=t.rotation
        if not finite(q.x) or not finite(q.y) or not finite(q.z) or not finite(q.w)
            or math.abs(q.x*q.x+q.y*q.y+q.z*q.z+q.w*q.w-1)>0.001 then
            return false,'invalid_rotation'
        end
        if math.abs(q.x)>0.00001 or math.abs(q.y)>0.00001 then return false,'yaw_only' end
        for _,axis in ipairs({'x','y','z'}) do
            if math.abs(t.scale[axis]-p.scale[axis])>0.00001 then return false,'scale_not_supported' end
        end
        if distance(t.position,s.origin)>10 or distance(t.position,a.position)>25 then
            return false,'out_of_bounds'
        end
        local yaw=math.deg(math.atan(2*q.w*q.z,1-2*q.z*q.z))
        return api.apply(s.prop,{position=t.position,yaw=yaw})
    end
    function S.cancel(player,token)
        local s=sessions[player]
        if not s or token~=s.token then return false,'invalid_ticket' end
        release(player); return true
    end
    function S.drop(player) release(player) end
    function S.tick()
        for player,s in pairs(sessions) do
            local valid,why=validate(player,s)
            if not valid then release(player); api.closed(player,s.token,why) end
        end
    end
    function S.clear()
        for player,s in pairs(sessions) do
            release(player); api.closed(player,s.token,'resource_stopped')
        end
    end
    return S
end
