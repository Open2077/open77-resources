-- Native presentation is an adapter, not network authority. The server is the
-- only producer of states; requests carry the authenticated sender, never a
-- client-selected participant. This controller is independently testable.
PlayerInteractionController = {}
local function copy(v)
    if type(v) ~= 'table' then return v end
    local r = {}; for k, x in pairs(v) do r[k] = copy(x) end; return r
end
local function finite(n) return type(n) == 'number' and n == n and math.abs(n) < math.huge end
local function integer(n, min, max) return finite(n) and n == math.floor(n) and n >= min and n <= max end
local function id(v) return type(v) == 'string' and #v == 32 and not v:find('[^a-f0-9]') end
local phases = { offered=true, preparing=true, scheduled=true, active=true, completed=true, cancelled=true }
local kinds = { give=true, heal=true, carry=true, escort=true, custom=true }
local function valid(s)
    return type(s) == 'table' and id(s.id) and id(s.epoch) and kinds[s.kind] and phases[s.phase] and
        integer(s.revision, 1, 9007199254740991) and integer(s.bucket, 0, 4294967295) and
        integer(tonumber(s.actor), 1, 9007199254740991) and integer(tonumber(s.target), 1, 9007199254740991) and
        tostring(s.actor) ~= tostring(s.target) and type(s.options) == 'table' and
        finite(s.serverTimeMs) and finite(s.startsAtMs) and finite(s.endsAtMs)
end
local function terminal(s) return s.phase == 'completed' or s.phase == 'cancelled' end

function PlayerInteractionController.new(io, nonce)
    local api, states, rendered, acknowledged, replies, pages, revisions = {}, {}, {}, {}, {}, {}, {}
    local epoch, context, clockOffset, serial, syncAt, floor = nil, nil, 0, 0, 0, -1
    local function request(name, ...)
        serial = serial + 1
        local key = nonce .. ':' .. serial
        local ok, err = io.send(name, key, ...)
        if ok == false then return nil, err or 'transport_unavailable' end
        return key
    end
    local function stop(key)
        if rendered[key] then io.stop(key); rendered[key] = nil end
        acknowledged[key] = nil
    end
    local function reset()
        for key in pairs(rendered) do stop(key) end
        states, rendered, acknowledged, replies, pages, revisions = {}, {}, {}, {}, {}, {}
        epoch, floor, syncAt = nil, -1, 0
    end
    local function participant(s) return context and
        (tonumber(s.actor) == context.playerId or tonumber(s.target) == context.playerId) end
    function api.current(player)
        player = player or (context and context.playerId)
        for _, s in pairs(states) do
            if tonumber(s.actor) == player or tonumber(s.target) == player then return copy(s) end
        end
    end
    function api.get(key) return copy(states[key]) end
    function api.list()
        local r = {}; for _, s in pairs(states) do r[#r+1] = copy(s) end
        table.sort(r, function(a,b) return a.revision < b.revision end); return r
    end
    function api.isReserved(player) return api.current(player) ~= nil end
    function api.respond(key, accepted)
        local s = states[key]
        if not s or not context or tonumber(s.target) ~= context.playerId then return nil, 'not_invited' end
        if s.phase ~= 'offered' then return nil, 'not_offered' end
        if type(accepted) ~= 'boolean' then return nil, 'invalid_argument' end
        return request(accepted and 'accept' or 'decline', key)
    end
    function api.cancel(key)
        local s = key and states[key] or api.current()
        if not s or not participant(s) then return nil, 'not_participant' end
        return request('cancel', s.id)
    end
    function api.result(key) return replies[key] and copy(replies[key].value) end
    function api.receiveResult(r)
        if type(r) ~= 'table' or type(r.requestId) ~= 'string' or #r.requestId > 64 then return end
        replies[r.requestId] = {at=io.now(), value=copy(r)}
        io.emit('onPlayerInteractionResult', copy(r))
    end
    local function apply(s, fromSnapshot)
        if not valid(s) or not context or s.bucket ~= context.bucket then return end
        if epoch and s.epoch ~= epoch then return end -- only a complete snapshot can establish a new epoch
        if not epoch then epoch = s.epoch end
        if s.revision <= (revisions[s.id] or -1) or (not fromSnapshot and s.revision <= floor) then return end
        revisions[s.id] = s.revision
        clockOffset = s.serverTimeMs - io.now()
        if terminal(s) then
            stop(s.id); states[s.id] = nil
        else states[s.id] = copy(s) end
        io.emit('onPlayerInteractionChanged', copy(s))
        if s.phase == 'active' then io.emit('onPlayerInteractionStarted', copy(s)) end
        if s.phase == 'offered' and participant(s) and tonumber(s.target) == context.playerId then
            io.emit('onPlayerInteractionOffered', copy(s))
        elseif terminal(s) then
            io.emit(s.phase == 'completed' and 'onPlayerInteractionCompleted' or 'onPlayerInteractionCancelled', copy(s))
        end
    end
    function api.receiveState(s) apply(s, false) end
    function api.receiveSnapshot(p)
        if not context or type(p) ~= 'table' or not id(p.snapshotId) or not id(p.epoch) or
            p.bucket ~= context.bucket or not integer(p.revision, 0, 9007199254740991) or
            not integer(p.total, 1, 256) or not integer(p.slice, 1, p.total) or
            type(p.states) ~= 'table' or #p.states > 1 or not finite(p.serverTimeMs) then return end
        for _, s in ipairs(p.states) do
            if not valid(s) or s.epoch ~= p.epoch or s.bucket ~= p.bucket or s.revision > p.revision or terminal(s) then return end
        end
        local chunk = pages[p.snapshotId]
        if not chunk then
            local count=0; for _ in pairs(pages) do count=count+1 end
            if count >= 4 then return end
            chunk={at=io.now(), epoch=p.epoch, revision=p.revision, total=p.total, slices={}}
            pages[p.snapshotId]=chunk
        end
        if chunk.epoch ~= p.epoch or chunk.revision ~= p.revision or chunk.total ~= p.total then return end
        chunk.slices[p.slice] = copy(p.states)
        for n=1, chunk.total do if not chunk.slices[n] then return end end
        pages[p.snapshotId] = nil
        if epoch == p.epoch and p.revision < floor then return end
        if epoch ~= p.epoch then reset(); epoch = p.epoch end
        local seen={}
        for n=1, chunk.total do for _, s in ipairs(chunk.slices[n]) do seen[s.id]=true; apply(s,true) end end
        for key, s in pairs(states) do
            if not seen[key] and s.revision <= p.revision then stop(key); states[key]=nil; revisions[key]=nil end
        end
        floor = math.max(floor, p.revision)
        for key, revision in pairs(revisions) do if not states[key] and revision <= floor then revisions[key]=nil end end
        clockOffset = p.serverTimeMs-io.now()
    end
    function api.tick(current)
        if not current or not current.ready then reset(); context=current; return end
        if context and (context.generation ~= current.generation or context.bucket ~= current.bucket or
            context.playerId ~= current.playerId) then reset() end
        context = current
        local now = io.now()
        if now >= syncAt then request('sync'); syncAt=now+5000 end
        for key, r in pairs(replies) do if now-r.at > 30000 then replies[key]=nil end end
        for key, chunk in pairs(pages) do if now-chunk.at > 10000 then pages[key]=nil end end
        for key, s in pairs(states) do
            if s.phase ~= 'offered' then
                local stage = (s.phase == 'scheduled' or s.phase == 'active') and
                    now+clockOffset >= s.startsAtMs and 'active' or 'preparing'
                local entry = rendered[key]
                if not entry then entry={stage='new', failed=false}; rendered[key]=entry end
                local ended = s.endsAtMs > 0 and now+clockOffset >= s.endsAtMs
                if ended and not entry.ended then io.stop(key); entry.ended=true end
                local status = (entry.failed or entry.ended) and 'pending' or
                    io.present(copy(s), stage, current, entry.stage ~= stage)
                entry.stage=stage
                if status ~= 'ok' and status ~= 'pending' and not entry.failed then
                    entry.failed=true
                    io.stop(key)
                    io.emit('onPlayerInteractionPresentationFailed', key, status)
                    if participant(s) then
                        if s.phase == 'preparing' then request('ready',key,s.revision,false)
                        else request('cancel',key) end
                    end
                elseif participant(s) then
                    if s.phase == 'preparing' and status == 'ok' then
                        local ack=acknowledged[key]
                        if not ack or ack.revision ~= s.revision or now-ack.at >= 1500 then
                            request('ready',key,s.revision,true)
                            acknowledged[key]={revision=s.revision,at=now}
                        end
                    end
                end
            end
        end
    end
    function api.shutdown() reset(); context=nil end
    return api
end
