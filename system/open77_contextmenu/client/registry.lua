-- Pure registry: ownership is supplied by the runtime, never by a browser.
ContextMenuRegistry = {}
local kinds = { player=true, vehicle=true, npc=true, prop=true, door=true,
    device=true, item=true, object=true, world=true, sky=true }
local function finite(n) return type(n)=="number" and n==n and math.abs(n)<math.huge end
local function text(v,n) return type(v)=="string" and #v>0 and #v<=n and not v:find("[%c]") end
local function name(v) return text(v,64) and v:match("^[%w_%.:%-]+$")~=nil end
local function copy(v)
    if type(v)~="table" then return v end
    local out={};for k,item in pairs(v) do out[k]=copy(item) end;return out
end
local function dense(v,max)
    if type(v)~="table" or #v<1 or #v>max then return false end
    local count=0;for k in pairs(v) do if type(k)~="number" or k%1~=0 or k<1 or k>#v then return false end;count=count+1 end
    return count==#v
end
local function dataValid(value)
    local remaining,seen=2048,{}
    local function visit(v,depth)
        remaining=remaining-8
        if remaining<0 or depth>4 then return false end
        if type(v)=="string" then remaining=remaining-#v;return remaining>=0 end
        if type(v)=="number" then return finite(v) end
        if type(v)=="boolean" or v==nil then return true end
        if type(v)~="table" or seen[v] or (getmetatable and getmetatable(v)) then return false end
        seen[v]=true
        for k,item in pairs(v) do
            if not ((type(k)=="string" and #k<=64) or (finite(k) and k%1==0 and k>=1 and k<=64)) or not visit(k,depth+1) or not visit(item,depth+1) then return false end
        end
        seen[v]=nil;return true
    end
    return visit(value,0)
end
local function selectorValid(v)
    if type(v)~="table" then return false end
    local count=0
    for k,id in pairs(v) do
        count=count+1
        if k=="playerId" or k=="vehicleId" or k=="npcId" then
            -- Vehicle/NPC IDs carry a generation and can exceed uint32.
            -- Keep exact Lua integers; reject imprecise double representations.
            if not finite(id) or id%1~=0 or id<1 or
                (math.type(id)~="integer" and id>9007199254740991) then return false end
        elseif k=="engineEntity" or k=="propId" then
            if type(id)~="string" or #id>20 or not id:match("^[1-9]%d*$") then return false end
        else return false end
    end
    return count==1
end
local function array(value, validate)
    if value==nil then return nil,true end
    if type(value)~="table" or #value>32 then return nil,false end
    local out,count={},0
    for k,v in pairs(value) do
        if type(k)~="number" or k%1~=0 or k<1 or k>#value or not validate(v) then return nil,false end
        out[v]=true; count=count+1
    end
    return out,count==#value and count>0
end
-- Registration is linear in the batch, never in the registry. The first
-- version counted every registered action per definition and copied the whole
-- table before a batch, so a batch of five with a hundred actions already
-- registered cost ~12 000 VM instructions -- past the 10 000-instruction hook
-- interval of the client host, which on a loaded client kills the resume at
-- its first hook. Measured 2026-09-18: open77_admin logged `context
-- registration failed: registry.lua:127: Open77 script execution budget
-- exceeded` at every start on an RP server where ~70 resources shared the
-- host and several registered context actions in the same tick. The count
-- and the id lookup are now indexes kept by `insert`/`erase`, and a failed
-- batch undoes its own journal instead of restoring a copy. Same limits (128
-- total, 32 per owner), same id replacement, same atomic rollback.
local ICONS={interact=true,person=true,vehicle=true,info=true,lock=true,tool=true,location=true}
local FLAGS={"enabled","networked","allowSelf","selfOnly","danger"}
local FIELDS={"id","label","onSelect","canInteract","description","group","icon","enabled","networked","allowSelf","selfOnly","danger","distance","order","types","records","entities","data"}
function ContextMenuRegistry.new(alive)
    local actions,sequence={},0
    -- Indexes over `actions`: the total, one count per owner, and per owner
    -- the token each id currently occupies. Every mutation goes through
    -- `insert`/`erase` so they cannot drift.
    local total,ownerCount,ownerIds=0,{},{}
    local function insert(a)
        actions[a.token]=a
        total=total+1
        ownerCount[a.owner]=(ownerCount[a.owner] or 0)+1
        local ids=ownerIds[a.owner]
        if not ids then ids={};ownerIds[a.owner]=ids end
        ids[a.id]=a.token
    end
    local function erase(token)
        local a=actions[token]
        if not a then return nil end
        actions[token]=nil
        total=total-1
        local remaining=ownerCount[a.owner]-1
        if remaining>0 then
            ownerCount[a.owner]=remaining
            local ids=ownerIds[a.owner]
            if ids[a.id]==token then ids[a.id]=nil end
        else
            ownerCount[a.owner]=nil;ownerIds[a.owner]=nil
        end
        return a
    end
    local api={}
    function api.removeOwner(owner)
        for token,a in pairs(actions) do if a.owner==owner then erase(token) end end
    end
    function api.sweep()
        for token,a in pairs(actions) do if not alive(a.owner,a.generation) then erase(token) end end
    end
    -- One validated definition into the registry, after the caller has swept.
    -- Returns the token and the action it replaced, so a batch can undo it.
    local function registerOne(owner,generation,d)
        if not name(owner) or type(generation)~="number" or not alive(owner,generation) then return nil,"invalid_owner" end
        if type(d)~="table" or not name(d.id) or not text(d.label,80) or not name(d.onSelect) then return nil,"invalid_action" end
        if d.canInteract~=nil and not name(d.canInteract) then return nil,"invalid_predicate" end
        if d.description~=nil and not text(d.description,180) then return nil,"invalid_description" end
        if d.group~=nil and not text(d.group,40) then return nil,"invalid_group" end
        if d.icon~=nil and not ICONS[d.icon] then return nil,"invalid_icon" end
        for _,field in ipairs(FLAGS) do
            if d[field]~=nil and type(d[field])~="boolean" then return nil,"invalid_"..field end
        end
        local distance=d.distance or 3.0
        if not finite(distance) or distance<0.1 or distance>50 then return nil,"invalid_distance" end
        local order=d.order or 0
        if not finite(order) or order%1~=0 or math.abs(order)>1000 then return nil,"invalid_order" end
        local types,ok=array(d.types,function(v) return kinds[v]==true end)
        if not ok then return nil,"invalid_types" end
        local records,recordsOk=array(d.records,function(v) return text(v,200) end)
        if not recordsOk then return nil,"invalid_records" end
        if d.selfOnly and (not d.allowSelf or (types and not types.player)) then return nil,"invalid_self_filter" end
        if d.entities~=nil then
            if not dense(d.entities,32) then return nil,"invalid_entities" end
            for _,v in ipairs(d.entities) do if not selectorValid(v) then return nil,"invalid_entities" end end
        end
        if not dataValid(d.data) then return nil,"invalid_data" end
        local ids=ownerIds[owner]
        local previous=ids and ids[d.id] or nil
        if not previous and (total>=128 or (ownerCount[owner] or 0)>=32) then return nil,"action_limit" end
        local replaced=previous and erase(previous) or nil
        sequence=sequence+1
        local token=tostring(sequence)
        local action={token=token,owner=owner,generation=generation,id=d.id,label=d.label,
            description=d.description,group=d.group or "Actions",icon=d.icon or "interact",
            onSelect=d.onSelect,canInteract=d.canInteract,types=types,records=records,
            distance=distance,order=order,enabled=d.enabled~=false,networked=d.networked,
            allowSelf=d.allowSelf==true,selfOnly=d.selfOnly==true,danger=d.danger==true,
            entities=copy(d.entities),data=copy(d.data)}
        -- Keep only supported fields; never retain a provider's Lua table.
        local definition={}
        for _,field in ipairs(FIELDS) do definition[field]=copy(d[field]) end
        action.definition=definition
        insert(action)
        return token,replaced
    end
    function api.register(owner,generation,d)
        api.sweep()
        local token,err=registerOne(owner,generation,d)
        if not token then return nil,err end
        return token
    end
    function api.registerMany(owner,generation,definitions)
        if not dense(definitions,32) then return nil,"invalid_actions" end
        local ids={}
        for _,d in ipairs(definitions) do
            if type(d)~="table" or not name(d.id) or ids[d.id] then return nil,"invalid_or_duplicate_id" end
            ids[d.id]=true
        end
        api.sweep()
        -- Atomic: on any failure the batch is undone newest-first, putting
        -- back whatever each registration replaced under its old token.
        local tokens,journal={},{}
        for _,d in ipairs(definitions) do
            local token,result=registerOne(owner,generation,d)
            if not token then
                for index=#journal,1,-1 do
                    local step=journal[index]
                    erase(step.token)
                    if step.replaced then insert(step.replaced) end
                end
                return nil,result
            end
            tokens[#tokens+1]=token
            journal[#journal+1]={token=token,replaced=result}
        end
        return tokens
    end
    function api.update(owner,generation,token,patch)
        local a=api.get(token)
        if not a or a.owner~=owner then return nil,"not_owner" end
        if type(patch)~="table" or (patch.id~=nil and patch.id~=a.id) then return nil,"invalid_patch" end
        local d=copy(a.definition);for k,v in pairs(patch) do d[k]=v end
        return api.register(owner,generation,d) -- revokes old in-flight menus
    end
    function api.describe(owner,token)
        local a=api.get(token)
        if not a or a.owner~=owner then return nil,"not_owner" end
        return {token=token,definition=copy(a.definition)}
    end
    function api.unregister(owner,token)
        local a=actions[token]
        if not a then return false,"action_not_found" end
        if a.owner~=owner then return false,"not_owner" end
        erase(token); return true
    end
    function api.setEnabled(owner,token,value)
        local a=actions[token]
        if not a or a.owner~=owner then return false,"not_owner" end
        if type(value)~="boolean" then return false,"expected_boolean" end
        a.enabled=value;a.definition.enabled=value; return true
    end
    function api.unregisterMany(owner,tokens)
        if not dense(tokens,32) then return false,"invalid_tokens" end
        for _,token in ipairs(tokens) do local a=actions[token];if not a or a.owner~=owner then return false,"not_owner" end end
        for _,token in ipairs(tokens) do erase(token) end;return true
    end
    function api.get(token) api.sweep();return actions[token] end
    function api.matches(a,context)
        local target=context.target or {kind="world",networked=false}
        -- Empty space is opt-in, never disguised as a zero-distance surface.
        local distanceOk=target.kind=="sky" and a.types and a.types.sky==true or
            target.kind~="sky" and finite(context.playerDistance) and context.playerDistance>=0 and context.playerDistance<=a.distance
        local entityOk=not a.entities
        for _,selector in ipairs(a.entities or {}) do for k,id in pairs(selector) do if target[k]==id then entityOk=true end end end
        return a.enabled and alive(a.owner,a.generation) and distanceOk and entityOk and
            (not target.isLocalPlayer or a.allowSelf) and (not a.selfOnly or target.isLocalPlayer==true) and
            (not a.types or a.types[target.kind]==true) and (not a.records or a.records[target.record]==true) and
            (a.networked==nil or a.networked==target.networked)
    end
    function api.candidates(context)
        api.sweep(); local out={}
        for _,a in pairs(actions) do if api.matches(a,context) then out[#out+1]=a end end
        table.sort(out,function(a,b)
            if a.order~=b.order then return a.order<b.order end
            if a.group~=b.group then return a.group<b.group end
            if a.label~=b.label then return a.label<b.label end
            return a.token<b.token
        end)
        return out
    end
    function api.list(owner)
        api.sweep();local out={}
        for _,a in pairs(actions) do if a.owner==owner then
            out[#out+1]={token=a.token,id=a.id,label=a.label,enabled=a.enabled}
        end end
        table.sort(out,function(a,b) return a.id<b.id end);return out
    end
    return api
end
