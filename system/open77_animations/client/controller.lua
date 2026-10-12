-- Deterministic reconciliation, independently executable in tests. The adapter
-- supplies trusted network events and native presentation; this module owns no rig.
RpAnimationController = {}

local function integer(n, low, high)
    return type(n) == 'number' and n == math.floor(n) and n >= low and n <= high
end
local function copy(value)
    if type(value) ~= 'table' then return value end
    local result = {}
    for k, v in pairs(value) do result[k] = copy(v) end
    return result
end
local function text(value, maximum)
    return type(value) == 'string' and #value > 0 and #value <= maximum and not value:find('\0', 1, true)
end
local function array(value, maximum)
    if type(value) ~= 'table' or #value > maximum then return false end
    local count = 0
    for k in pairs(value) do
        if not integer(k, 1, #value) then return false end
        count = count + 1
    end
    return count == #value
end

function RpAnimationController.new(io, catalogue, nonce)
    local api = {}
    local profiles, clips, clipRows = {}, {}, {}
    for _, p in ipairs(catalogue.profiles) do
        profiles[p.id], clips[p.id] = p, {}
        for _, clip in ipairs(p.clips) do
            clips[p.id][clip] = true
            clipRows[#clipRows + 1] = { clip = clip, profile = p.id }
        end
    end
    table.sort(clipRows, function(a, b) return a.clip < b.clip end)
    -- Clip -> profile, generated alongside the catalogue. A clip is addressable
    -- only because exactly one shipped device's authored tree carries it.
    local clipIndex = catalogue.clipIndex or {}
    local epoch, floor, canonical, rendered, blocked = nil, -1, {}, {}, {}
    local pending, replies, cancelled, stopRequests, chunks, owners = {}, {}, {}, {}, {}, {}
    local snapshotChanges = {}
    local context, serial, nextSync = nil, 0, 0
    local function requestId()
        serial = serial + 1
        return nonce .. ':' .. serial
    end
    local function stopBody(player)
        local old = rendered[player]
        if old then io.stop(old.entity); rendered[player] = nil end
    end
    local function sendStop(id)
        local cancel = cancelled[id] or { at = 0 }
        cancelled[id] = cancel
        if io.now() >= cancel.at then
            if cancel.requestId then stopRequests[cancel.requestId] = nil end
            cancel.requestId, cancel.at = requestId(), io.now() + 1000
            stopRequests[cancel.requestId] = id
            io.send('stopRequest', cancel.requestId, id)
        end
    end
    local function forgetStop(id)
        local cancel = cancelled[id]
        if cancel and cancel.requestId then stopRequests[cancel.requestId] = nil end
        cancelled[id] = nil
    end
    local function reply(id, result)
        replies[id] = { at = io.now(), value = copy(result) }
    end
    local function abandon(id, request, reason)
        if not request.abandoned then reply(id, { ok = false, error = reason }) end
        request.abandoned = true
    end
    local function refreshRequest(id, request)
        if not io.ownerAlive(request.owner) then abandon(id, request, 'resource_stopped')
        elseif io.now() - request.at >= 10000 then abandon(id, request, 'request_timeout') end
    end
    local function blockLocal(s)
        local own = context and canonical[context.playerId]
        -- A late reply for A must not erase the cancellation/native-failure guard
        -- of a newer B. Cancellation retries are keyed by playback, not player.
        if not own or own.playbackId == s.playbackId then
            blocked[s.playerId] = { id = s.playbackId, permanent = true }
            stopBody(s.playerId)
        end
        sendStop(s.playbackId)
    end
    local function reconcileLocal(s)
        if not s or not s.active or not context or s.playerId ~= context.playerId then return end
        local request = s.clientRequestId and pending[s.clientRequestId]
        if not request then return end
        refreshRequest(s.clientRequestId, request)
        if request.abandoned then blockLocal(s)
        else owners[s.playbackId] = request.owner end
    end
    function api.reset()
        for player in pairs(rendered) do stopBody(player) end
        epoch, floor, canonical, blocked, chunks, snapshotChanges = nil, -1, {}, {}, {}, {}
        for id, request in pairs(pending) do abandon(id, request, 'session_changed') end
        pending, cancelled, stopRequests, owners, nextSync = {}, {}, {}, {}, 0
    end
        -- I4. A placed action carries the pose its workspot device is spawned at.
    -- Validated like everything else on this wire even though the transport
    -- already refuses non-server sources: a malformed anchor that reached the
    -- native would put a body somewhere nobody asked for.
    local function anchorOf(s)
        local a = s.anchor
        if a == nil then return nil, true end
        if type(a) ~= 'table' then return nil, false end
        local function finite(v) return type(v) == 'number' and v == v and v > -1e9 and v < 1e9 end
        if not finite(a.x) or not finite(a.y) or not finite(a.z) then return nil, false end
        if a.yaw ~= nil and not finite(a.yaw) then return nil, false end
        return { x = a.x, y = a.y, z = a.z, yaw = a.yaw or 0 }, true
    end
    local function valid(s)
        if type(s) ~= 'table' or not text(s.epoch, 64) or not text(s.playbackId, 64) or
            not integer(s.revision, 0, 9007199254740991) or not integer(s.playerId, 1, 9007199254740991) or
            type(s.active) ~= 'boolean' or not integer(s.bucket, 0, 4294967295) or
            (s.clientRequestId ~= nil and s.clientRequestId ~= '' and not text(s.clientRequestId, 64)) or
            not array(s.steps, 16) or #s.steps < 1 or
            not integer(s.step, 0, #s.steps - 1) or not integer(s.cycle, 0, 9007199254740991) then return false end
        local _, anchorOk = anchorOf(s)
        if not anchorOk then return false end
        for _, step in ipairs(s.steps) do
            if type(step) ~= 'table' or not clips[step.profile] or not clips[step.profile][step.clip] or
                not integer(step.durationMs, 0, 600000) then return false end
        end
        return true
    end
    local function apply(s, snapshot)
        if not valid(s) or (epoch and epoch ~= s.epoch) then return false end
        if s.active and context and s.bucket ~= context.bucket then return false end
        local old = canonical[s.playerId]
        if (not snapshot and s.revision <= floor) or (old and old.revision >= s.revision) then return false end
        epoch = s.epoch
        canonical[s.playerId] = copy(s)
        snapshotChanges[s.playerId] = nil -- a newer live event supersedes a queued snapshot notification
        if old and old.playbackId ~= s.playbackId then forgetStop(old.playbackId) end
        if not s.active then stopBody(s.playerId); forgetStop(s.playbackId); blocked[s.playerId] = nil end
        reconcileLocal(s) -- the server broadcasts state before the request acknowledgement
        io.emit('onPlayerAnimationChanged', s.playerId, copy(s))
        return true
    end
    function api.receiveState(s) return apply(s, false) end
    function api.receiveSnapshot(s)
        if type(s) ~= 'table' or not text(s.epoch, 64) or (epoch and epoch ~= s.epoch) or
            not integer(s.revision, 0, 9007199254740991) or s.revision < floor or
            not integer(s.bucket, 0, 4294967295) or (context and s.bucket ~= context.bucket) or
            not array(s.states, 64) then return false end
        -- Validate/copy each small wire page on its own scheduler resume. The
        -- final page must not repeat that work for a whole 4096-player roster.
        local prepared = {}
        for _, item in ipairs(s.states) do
            if not valid(item) or item.epoch ~= s.epoch or item.bucket ~= s.bucket or
                item.revision > s.revision or not item.active or prepared[item.playerId] then return false end
            prepared[item.playerId] = copy(item)
        end
        -- Assemble bounded pages before treating absence as a removal.
        if s.total then
            if not text(s.snapshotId, 64) or not integer(s.total, 1, 512) or
                not integer(s.slice, 1, s.total) then return false end
            local batch = chunks[s.snapshotId]
            if not batch then
                chunks = {} -- at most one in-flight snapshot, reliable ordered channel
                batch = { at = io.now(), total = s.total, revision = s.revision,
                    epoch = s.epoch, bucket = s.bucket, count = 0, received = 0, sizes = {}, pages = {} }
                chunks[s.snapshotId] = batch
            end
            if batch.total ~= s.total or batch.revision ~= s.revision or
                batch.epoch ~= s.epoch or batch.bucket ~= s.bucket then return false end
            batch.count = batch.count - (batch.sizes[s.slice] or 0) + #s.states
            if batch.count > 4096 then chunks = {}; return false end
            if not batch.pages[s.slice] then batch.received = batch.received + 1 end
            batch.pages[s.slice], batch.sizes[s.slice] = prepared, #s.states
            if batch.received ~= batch.total then return true end
            local all = {}
            for i = 1, batch.total do
                if not batch.pages[i] then return true end
                for player, item in pairs(batch.pages[i]) do
                    if all[player] then chunks = {}; return false end
                    all[player] = item
                end
            end
            prepared, chunks = all, {}
        end
        -- Commit with shallow references to the already validated immutable
        -- states. User-facing copies/events are drained in bounded batches.
        local nextCanonical = {}
        for player, old in pairs(canonical) do
            local item = prepared[player]
            if old.revision > s.revision or (item and old.revision >= item.revision) then
                nextCanonical[player] = old
                prepared[player] = nil
            elseif not item then
                stopBody(player)
                if old.active then
                    local removed = {}
                    for key, value in pairs(old) do removed[key] = value end
                    removed.active, removed.reason, removed.revision = false, 'snapshot_removed', s.revision
                    snapshotChanges[player] = removed
                end
                forgetStop(old.playbackId); blocked[player] = nil
            elseif old.playbackId ~= item.playbackId then
                forgetStop(old.playbackId)
            end
        end
        for player, item in pairs(prepared) do
            nextCanonical[player], snapshotChanges[player] = item, item
        end
        epoch, floor, canonical = s.epoch, s.revision, nextCanonical
        reconcileLocal(context and canonical[context.playerId])
        return true
    end
    function api.receiveResult(result)
        if type(result) ~= 'table' or type(result.requestId) ~= 'string' or type(result.ok) ~= 'boolean' then return end
        local stop = stopRequests[result.requestId]
        if stop then
            if result.ok or result.error == 'stale_playback' then forgetStop(stop) end
            return
        end
        local request = pending[result.requestId]
        if not request then return end
        refreshRequest(result.requestId, request)
        pending[result.requestId] = nil
        if result.ok and (not valid(result.value) or not context or
            result.value.playerId ~= context.playerId or result.value.bucket ~= context.bucket or
            (epoch and result.value.epoch ~= epoch) or
            (result.value.clientRequestId ~= nil and result.value.clientRequestId ~= '' and
                result.value.clientRequestId ~= result.requestId)) then
            if not request.abandoned then reply(result.requestId, { ok = false, error = 'invalid_response' }) end
            return
        end
        if not request.abandoned then reply(result.requestId, result) end
        if result.ok then
            if request.abandoned then
                if result.value.active then blockLocal(result.value) end
            else
                owners[result.value.playbackId] = request.owner
                apply(result.value, false)
            end
        end
        io.emit('onAnimationResult', result.requestId, result.ok, result.error, copy(result.value))
    end
    local function submit(owner, name, ...)
        if not context or not context.ready then return nil, 'player_not_ready' end
        local count = 0
        for _ in pairs(pending) do count = count + 1 end
        if count >= 32 then return nil, 'too_many_requests' end
        local id = requestId()
        pending[id] = { owner = copy(owner), at = io.now() }
        local ok, err = io.send(name, id, ...)
        if not ok then pending[id] = nil; return nil, err or 'network_unavailable' end
        return id
    end
    function api.request(owner, profile, options)
        if not profiles[profile] then return nil, 'unknown_profile' end
        return submit(owner, 'request', profile, options or {})
    end
    function api.sequence(owner, steps, options) return submit(owner, 'sequenceRequest', steps, options or {}) end
    function api.cancel(id)
        local own = context and canonical[context.playerId]
        if not id then for key, request in pairs(pending) do abandon(key, request, 'cancelled') end end
        if not own or not own.active then return true end
        if id and id ~= own.playbackId then return nil, 'stale_playback' end
        blocked[own.playerId] = { id = own.playbackId, permanent = true }
        stopBody(own.playerId)
        sendStop(own.playbackId)
        return true
    end
    function api.result(id)
        local request = pending[id]
        if request then refreshRequest(id, request) end
        local result = replies[id]
        if result then replies[id] = nil; return result.value end
        if not request then return { ok = false, error = 'request_unavailable' } end
    end
    function api.requestClip(owner, clip, options)
        if type(clip) ~= 'string' or #clip == 0 or #clip > 160 then return nil, 'unknown_clip' end
        local profile = clipIndex[clip]
        if not profile then return nil, 'unknown_clip' end
        -- Resolved locally so the wire keeps one request shape; the server
        -- re-validates the clip against the same generated catalogue.
        local resolved = {}
        for key, value in pairs(options or {}) do resolved[key] = value end
        resolved.clip = clip
        return submit(owner, 'request', profile, resolved)
    end
    function api.get(id) return copy(profiles[id]) end
    function api.clip(name)
        local profile = type(name) == 'string' and clipIndex[name] or nil
        return profile and copy(profiles[profile]) or nil
    end
    -- Export-only borrowed views are serialized/deep-copied by ResourceHost at
    -- the VM boundary. Avoid recursively copying/sorting the entire immutable
    -- catalogue inside a 50us live resource slice. Internal callers retain the
    -- defensive-copy default; no caller-supplied export argument enables this.
    function api.clips(query, exportView)
        if query ~= nil and (type(query) ~= 'string' or #query > 128) then return nil, 'invalid_query' end
        query = (query or ''):lower()
        if query == '' then return exportView and clipRows or copy(clipRows) end
        local result = {}
        for _, row in ipairs(clipRows) do
            if (row.clip .. ' ' .. row.profile):lower():find(query, 1, true) then
                result[#result + 1] = exportView and row or copy(row)
            end
        end
        return result
    end
    function api.list(query, exportView)
        if query ~= nil and (type(query) ~= 'string' or #query > 128) then return nil, 'invalid_query' end
        query = (query or ''):lower()
        if query == '' then return exportView and catalogue.profiles or copy(catalogue.profiles) end
        local result = {}
        for _, p in ipairs(catalogue.profiles) do
            if (p.id .. ' ' .. p.label .. ' ' .. p.category):lower():find(query, 1, true) then
                result[#result + 1] = exportView and p or copy(p)
            end
        end
        return result
    end
    function api.state(player)
        local s = canonical[player or (context and context.playerId)]
        return s and s.active and copy(s) or nil
    end
    function api.isPointing(player)
        local s = api.state(player)
        local failure = s and blocked[s.playerId]
        return s ~= nil and s.steps[s.step + 1].profile == 'camera_point' and
            not (failure and failure.id == s.playbackId)
    end
    function api.requestPointing(owner)
        local current = api.state()
        if current then
            local heldBy = owners[current.playbackId]
            if api.isPointing() and heldBy and heldBy.name == owner.name and heldBy.generation == owner.generation then
                return nil, nil, current
            end
            return nil, 'animation_busy'
        end
        for _, request in pairs(pending) do
            if not request.abandoned then return nil, 'request_pending' end
        end
        local id, err = api.request(owner, 'camera_point', { loop = true })
        if id then pending[id].pointing = true end
        return id, err
    end
    function api.stopPointing(owner)
        local function sameOwner(value)
            return value and owner and value.name == owner.name and value.generation == owner.generation
        end
        -- Releasing before the server reply must also cancel that late reply.
        -- Never cancel another resource's gesture or a replacement animation.
        for id, request in pairs(pending) do
            if request.pointing and sameOwner(request.owner) then abandon(id, request, 'cancelled') end
        end
        local s = api.state()
        if not s or s.steps[s.step + 1].profile ~= 'camera_point' then return true end
        if not sameOwner(owners[s.playbackId]) then return nil, 'not_owner' end
        return api.cancel(s.playbackId)
    end
    function api.tick(current)
        if context and (context.generation ~= current.generation or context.bucket ~= current.bucket or
            context.playerId ~= current.playerId or (context.ready and not current.ready)) then api.reset() end
        context = current
        if not current.ready then return end
        local emitted = 0
        for player, change in pairs(snapshotChanges) do
            snapshotChanges[player] = nil
            io.emit('onPlayerAnimationChanged', player, copy(change))
            emitted = emitted + 1
            if emitted >= 32 then break end
        end
        local now = io.now()
        if now >= nextSync then io.send('sync', requestId()); nextSync = now + 5000 end
        for id, cancel in pairs(cancelled) do if now >= cancel.at then sendStop(id) end end
        for id, batch in pairs(chunks) do if now - batch.at > 10000 then chunks[id] = nil end end
        for id, completed in pairs(replies) do if now - completed.at > 60000 then replies[id] = nil end end
        for id, request in pairs(pending) do
            refreshRequest(id, request)
        end
        local own = canonical[current.playerId]
        reconcileLocal(own)
        for id, ownedBy in pairs(owners) do
            if not own or not own.active or own.playbackId ~= id then owners[id] = nil
            elseif not io.ownerAlive(ownedBy) then api.cancel(id); owners[id] = nil end
        end
        for player, old in pairs(rendered) do
            local entity = player == current.playerId and 0 or current.players[player]
            if entity ~= old.entity then stopBody(player) end
        end
        for player, s in pairs(canonical) do
            local entity = player == current.playerId and 0 or current.players[player]
            -- The anchor belongs in the signature: the same playback moved to a
            -- new pose is a new device, and a signature that ignored it would
            -- leave the body sitting at the old one.
            local anchor = anchorOf(s)
            local signature = s.playbackId .. ':' .. s.cycle .. ':' .. s.step ..
                (anchor and (':%g:%g:%g:%g'):format(anchor.x, anchor.y, anchor.z, anchor.yaw) or '')
            local failure = blocked[player]
            if failure and not failure.permanent and
                (entity ~= failure.entity or signature ~= failure.signature) then
                blocked[player], failure = nil, nil
            end
            if s.active and entity ~= nil and (not failure or failure.id ~= s.playbackId) then
                local step = s.steps[s.step + 1]
                local old = rendered[player]
                if not old or old.signature ~= signature then
                    local restart = old and old.profile == step.profile and old.clip == step.clip or false
                    local ok, err = io.play(entity, step.profile, step.clip, restart, anchor)
                    if ok then
                        rendered[player] = { entity = entity, signature = signature, profile = step.profile, clip = step.clip }
                    else
                        blocked[player] = { id = s.playbackId, entity = entity, signature = signature,
                            permanent = player == current.playerId }; stopBody(player)
                        if player == current.playerId then sendStop(s.playbackId) end
                        io.emit('onAnimationPlaybackFailed', player, s.playbackId, err)
                    end
                else
                    local status = io.status(entity)
                    if status ~= 'ok' and status ~= 'device_pending' then
                        blocked[player] = { id = s.playbackId, entity = entity, signature = signature,
                            permanent = player == current.playerId }; stopBody(player)
                        if player == current.playerId then sendStop(s.playbackId) end
                        io.emit('onAnimationPlaybackFailed', player, s.playbackId, status)
                    end
                end
            end
        end
    end
    function api.shutdown()
        api.cancel()
        for _, request in pairs(pending) do request.abandoned = true end
        for player in pairs(rendered) do stopBody(player) end
    end
    return api
end
