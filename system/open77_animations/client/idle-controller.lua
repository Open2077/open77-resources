-- Persistent idle choice; the native presentation owners suspend/resume the pose.
-- io receives server-authenticated events only. No bank/clip art allowlist.
IdleAnimationController = {}
local function integer(v, lo, hi) return type(v)=='number' and v==math.floor(v) and v>=lo and v<=hi end
local function text(v, n) return type(v)=='string' and #v>0 and #v<=n and not v:find('%c') end
local function copy(v) if type(v)~='table' then return v end local t={} for k,x in pairs(v) do t[k]=copy(x) end return t end
local function valid(s)
    if type(s)~='table' or not text(s.epoch,64) or not integer(s.revision,1,9007199254740991) or
       not integer(s.playerId,1,9007199254740991) or not integer(s.bucket,0,4294967295) or type(s.active)~='boolean' then return false end
    if not s.active then return true end
    local o=s.options
    return type(o)=='table' and text(o.animset,512) and text(o.clip,192) and
        integer(o.blendMs,0,5000) and integer(o.delayMs,0,10000)
end
function IdleAnimationController.new(io, nonce)
    local api, states, rendered, pending, replies, owners = {}, {}, {}, {}, {}, {}
    local context, epoch, floor, batch, serial, nextSync = nil,nil,-1,nil,0,0
    local function id() serial=serial+1 return nonce..':i:'..serial end
    local function clear()
        io.clear(0); states={}; rendered={}; epoch=nil; floor=-1; batch=nil; owners={}
    end
    local function sendReset(revision) return io.send('idleReset',id(),revision) end
    local function adopt(s)
        local old=states[s.playerId]
        if old and old.revision>=s.revision then return end
        states[s.playerId]=copy(s)
        if s.active then
            local o=s.options
            io.apply(s.playerId,s.revision,o.animset,o.clip,o.blendMs,o.delayMs)
            rendered[s.playerId]=s.revision
        else io.clear(s.playerId); rendered[s.playerId]=nil end
        io.emit('onPlayerIdleChanged',s.playerId,copy(s))
    end
    function api.receiveState(s)
        if not context or not context.ready or not valid(s) or s.bucket~=context.bucket or s.revision<=floor then return end
        if epoch and s.epoch~=epoch then return end
        epoch=epoch or s.epoch
        adopt(s)
    end
    function api.receiveSnapshot(s)
        if not context or not context.ready or type(s)~='table' or not text(s.epoch,64) or
            (epoch and epoch~=s.epoch) or s.bucket~=context.bucket or not integer(s.revision,0,9007199254740991) or
            s.revision<floor or not integer(s.pages,1,43) or not integer(s.page,0,s.pages-1) or
            type(s.states)~='table' or #s.states>24 then return end
        for k,v in pairs(s.states) do
            if not integer(k,1,#s.states) or not valid(v) or not v.active or v.epoch~=s.epoch or
                v.bucket~=s.bucket or v.revision>s.revision then return end
        end
        if batch and batch.revision>s.revision then return end
        if not batch or batch.revision~=s.revision then batch={revision=s.revision,pages=s.pages,parts={}} end
        if batch.pages~=s.pages then return end
        batch.parts[s.page]=copy(s.states)
        for page=0,s.pages-1 do if not batch.parts[page] then return end end
        local nextStates={}
        for page=0,s.pages-1 do
            for _,v in ipairs(batch.parts[page]) do
                if nextStates[v.playerId] then batch=nil; return end
                nextStates[v.playerId]=v
            end
        end
        -- A delta received while the snapshot was in flight wins over that snapshot.
        for player,v in pairs(states) do if v.revision>s.revision then nextStates[player]=v end end
        for player in pairs(rendered) do if not nextStates[player] then io.clear(player); rendered[player]=nil end end
        local old=states; states={}; epoch=s.epoch; floor=s.revision; batch=nil
        for player,v in pairs(nextStates) do
            if old[player] and old[player].revision==v.revision then states[player]=v else adopt(v) end
        end
    end
    function api.receiveResult(r)
        if type(r)~='table' then return end
        local p=pending[r.requestId]
        if not p or type(r.ok)~='boolean' then return end
        pending[r.requestId]=nil
        if r.ok and p.kind=='idleRequest' then
            if not valid(r.value) or not context or r.value.playerId~=context.playerId or r.value.bucket~=context.bucket or
                (epoch and r.value.epoch~=epoch) then replies[r.requestId]={ok=false,error='invalid_reply'}; return end
            if p.abandoned or not io.ownerAlive(p.owner) then sendReset(r.value.revision)
            else owners[r.value.revision]=p.owner; api.receiveState(r.value) end
        end
        if not p.abandoned then replies[r.requestId]={ok=r.ok,error=r.error,value=copy(r.value)} end
    end
    function api.request(owner, options)
        if not context or not context.ready then return nil,'player_not_ready' end
        if type(options)~='table' then return nil,'invalid_options' end
        for _,p in pairs(pending) do if not p.abandoned then return nil,'request_pending' end end
        local key=id(); pending[key]={owner=owner,kind='idleRequest',at=io.now()}
        io.send('idleRequest',key,copy(options)); return key
    end
    function api.reset(owner)
        if not context or not context.ready then return nil,'player_not_ready' end
        for key,p in pairs(pending) do p.abandoned=true; replies[key]={ok=false,error='cancelled'} end
        local key=id(); pending[key]={owner=owner,kind='idleReset',at=io.now()}
        io.send('idleReset',key); return key
    end
    function api.result(key) local result=replies[key]; replies[key]=nil; return result end
    function api.get(player)
        player=player or (context and context.playerId)
        local s=player and states[player]
        if not s or not s.active then return nil end
        s=copy(s); s.status=io.status(player); return s
    end
    function api.tick(c)
        if not context or c.generation~=context.generation or c.playerId~=context.playerId or c.bucket~=context.bucket or not c.ready then
            clear(); pending={}; replies={}; nextSync=0
        end
        context=copy(c)
        if not c.ready then return end
        local now=io.now()
        if now>=nextSync then io.send('idleSync',id()); nextSync=now+5000 end
        for key,p in pairs(pending) do
            if not p.abandoned and (not io.ownerAlive(p.owner) or now-p.at>=10000) then
                p.abandoned=true; replies[key]={ok=false,error=io.ownerAlive(p.owner) and 'request_timeout' or 'resource_stopped'}
            end
            if now-p.at>=60000 then pending[key]=nil; replies[key]=nil end
        end
        local own=states[c.playerId]
        if own and own.active and owners[own.revision] and not io.ownerAlive(owners[own.revision]) then
            sendReset(own.revision); io.clear(c.playerId); owners[own.revision]=nil
        end
        for revision in pairs(owners) do if not own or own.revision~=revision then owners[revision]=nil end end
    end
    function api.shutdown()
        local own=context and states[context.playerId]
        if own and own.active and owners[own.revision] then sendReset(own.revision) end
        clear()
    end
    return api
end
