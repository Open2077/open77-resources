-- Durable server-owned bindings. Only authenticated server events reach this
-- controller; native handles and incarnation changes never come from a peer.
PlayerAttachmentController = {}
local function copy(v)
    if type(v)~='table' then return v end
    local t={} for k,x in pairs(v) do t[k]=copy(x) end return t
end
local function integer(v,lo,hi) return type(v)=='number' and v==math.floor(v) and v>=lo and v<=hi end
local function text(v,n,empty) return type(v)=='string' and (empty or #v>0) and #v<=n and not v:find('%c') end
local function token(v) return type(v)=='string' and #v==32 and not v:find('[^a-f0-9]') end
local function id(v)
    return type(v)=='string' and v:match('^[1-9][0-9]*$') and
        (#v<20 or #v==20 and v<='18446744073709551615')
end
local function vector(v,bound)
    if type(v)~='table' then return false end
    for _,k in ipairs({'x','y','z'}) do
        local n=v[k]
        if type(n)~='number' or n~=n or math.abs(n)>bound then return false end
    end
    return true
end
local function valid(s)
    if type(s)~='table' or not token(s.epoch) or not token(s.id) or
        not integer(s.revision,1,9007199254740991) or not id(s.playerId) or
        not id(s.parentId) or not text(s.incarnation,128) or not text(s.parentIncarnation,128) or
        not integer(s.bucket,0,4294967295) or (s.parentType~='player' and s.parentType~='vehicle') or
        not text(s.bone,192,true) or not vector(s.offset,1000) or not vector(s.rotation,360) or
        (s.phase~='pending' and s.phase~='active' and s.phase~='detached') then return false end
    local p=s.pose
    return p==nil or p==json.null or type(p)=='table' and text(p.animset,512) and
        p.animset:lower():sub(-6)=='.anims' and text(p.clip,192) and integer(p.blendMs,0,5000)
end
function PlayerAttachmentController.new(io)
    local api,states,rendered,acks,missing,failed={},{},{},{},{},{}
    local context,epoch,batch,floor,nextSync=nil,nil,nil,-1,0
    local function stop(player)
        if rendered[player] then io.stop(rendered[player]); rendered[player]=nil end
        missing[player]=nil; acks[player]=nil
    end
    local function clear()
        for player in pairs(rendered) do stop(player) end
        states={}; acks={}; missing={}; failed={}; epoch=nil; batch=nil; floor=-1; nextSync=0
    end
    local function adopt(s)
        local old=states[s.playerId]
        if old and old.revision>=s.revision then return end
        if old and old.id~=s.id or s.phase=='detached' then stop(s.playerId) end
        states[s.playerId]=copy(s); failed[s.playerId]=nil
        io.emit('onPlayerAttachmentChanged',copy(s))
    end
    function api.receiveState(s)
        if not context or not context.ready or not valid(s) or s.bucket~=context.bucket or
            s.revision<=floor or epoch and s.epoch~=epoch then return end
        epoch=epoch or s.epoch; adopt(s)
    end
    function api.receiveSnapshot(s)
        if not context or not context.ready or type(s)~='table' or not token(s.epoch) or
            epoch and s.epoch~=epoch or s.bucket~=context.bucket or not token(s.snapshotId) or
            not integer(s.revision,0,9007199254740991) or s.revision<floor or
            not integer(s.total,1,256) or not integer(s.slice,1,s.total) or
            type(s.states)~='table' or #s.states>1 then return end
        for k,v in pairs(s.states) do
            if k~=1 or not valid(v) or v.epoch~=s.epoch or v.bucket~=s.bucket or
                v.phase=='detached' or v.revision>s.revision then return end
        end
        if batch and batch.revision>s.revision then return end
        if not batch or batch.id~=s.snapshotId then
            batch={id=s.snapshotId,revision=s.revision,total=s.total,parts={}}
        end
        if batch.revision~=s.revision or batch.total~=s.total then return end
        batch.parts[s.slice]=copy(s.states)
        for page=1,s.total do if not batch.parts[page] then return end end
        local nextStates={}
        for page=1,s.total do
            for _,v in ipairs(batch.parts[page]) do
                if nextStates[v.playerId] then batch=nil; return end
                nextStates[v.playerId]=v
            end
        end
        -- A delta newer than the completed snapshot always wins.
        for player,v in pairs(states) do if v.revision>s.revision then nextStates[player]=v end end
        for player in pairs(rendered) do if not nextStates[player] then stop(player) end end
        for player,v in pairs(nextStates) do adopt(v) end
        states=nextStates; epoch=s.epoch; floor=s.revision; batch=nil
    end
    function api.tick(c)
        if not context or c.generation~=context.generation or c.playerId~=context.playerId or
            c.bucket~=context.bucket or not c.ready then clear() end
        context=copy(c)
        if not c.ready then return end
        local now=io.now()
        if now>=nextSync then io.send('sync'); nextSync=now+5000 end
        for player,s in pairs(states) do
            if s.phase~='detached' and failed[player]~=s.revision then
                local status=io.present(copy(s))
                rendered[player]=s.id -- even a pending native lease needs cleanup
                local localPlayer=player==tostring(c.playerId)
                local waiting=status=='pending'
                if waiting then missing[player]=missing[player] or now else missing[player]=nil end
                local failure=status~='ok' and not waiting or
                    localPlayer and s.phase=='active' and waiting and now-missing[player]>=5000
                local report=status=='ok' and s.phase=='pending' or failure
                if localPlayer and report and acks[player]~=s.revision then
                    io.send('ack',s.id,s.revision,not failure,waiting and 'parent_stream_timeout' or status)
                    acks[player]=s.revision
                end
                if failure then stop(player); failed[player]=s.revision end
            end
        end
    end
    function api.get(player)
        local s=states[tostring(player or (context and context.playerId))]
        return s and s.phase~='detached' and copy(s) or nil
    end
    function api.shutdown() clear(); context=nil end
    return api
end
