assert(load(CONTROLLER_SOURCE, '@controller.lua'))()
local passed = 0
local function test(name, run)
    local ok, err = pcall(run)
    assert(ok, name .. ': ' .. tostring(err))
    passed = passed + 1
end
local catalogue = { profiles = {
    { id = 'smoke', label = 'Smoke', category = 'social', clips = { 'smoke_a', 'smoke_b' } },
    { id = 'dance', label = 'Dance', category = 'social', clips = { 'dance_a' } },
} }
local function fixture(pointing)
    local f = { now = 0, calls = {}, events = {}, sent = {}, status = 'ok', alive = true,
        context = { ready = true, generation = 1, bucket = 0, playerId = 7, players = { [8] = 80 } } }
    f.api = RpAnimationController.new({
        now = function() return f.now end,
        play = function(...) f.calls[#f.calls + 1] = { 'play', ... }; return true end,
        stop = function(entity) f.calls[#f.calls + 1] = { 'stop', entity }; return true end,
        status = function() return f.status end,
        send = function(...) f.sent[#f.sent + 1] = { ... }; return true end,
        emit = function(...) f.events[#f.events + 1] = { ... } end,
        ownerAlive = function() return f.alive end,
    }, pointing and { profiles = { catalogue.profiles[1], catalogue.profiles[2],
        { id = 'camera_point', label = 'Point', category = 'social', clips = { 'camera_point' } } } } or catalogue, 'test')
    f.api.tick(f.context)
    f.sent = {}
    function f:tick() self.now = self.now + 100; self.api.tick(self.context) end
    function f:state(revision, id, player, active, clip)
        return { epoch = 'epoch', revision = revision, playbackId = id or 'action', playerId = player or 8,
            active = active ~= false, bucket = self.context.bucket, steps = { { profile = 'smoke', clip = clip or 'smoke_a', durationMs = 10000 } },
            step = 0, cycle = 0, loop = true }
    end
    function f:snapshot(revision, states)
        return { epoch = 'epoch', revision = revision, bucket = self.context.bucket, states = states }
    end
    return f
end
test('identical states are idempotent and stale stops cannot cancel replacement', function()
    local f = fixture()
    assert(f.api.receiveState(f:state(1))); f:tick()
    assert(#f.calls == 1 and f.calls[1][2] == 80)
    assert(not f.api.receiveState(f:state(1))); f:tick(); assert(#f.calls == 1)
    assert(f.api.receiveState(f:state(3, 'new'))); f:tick(); assert(#f.calls == 2)
    assert(not f.api.receiveState(f:state(2, 'action', 8, false)))
    assert(f.api.state(8).playbackId == 'new')
end)
test('snapshot absence retires body and retains a revision floor', function()
    local f = fixture(); f.api.receiveState(f:state(1)); f:tick()
    assert(f.api.receiveSnapshot(f:snapshot(3, {})))
    assert(f.calls[2][1] == 'stop' and not f.api.state(8))
    assert(not f.api.receiveState(f:state(2))); f:tick(); assert(#f.calls == 2)
end)
test('old snapshots preserve newer live actions', function()
    local f = fixture(); f.api.receiveState(f:state(5, 'new')); f:tick()
    assert(f.api.receiveSnapshot(f:snapshot(3, {})))
    assert(f.api.state(8).playbackId == 'new' and #f.calls == 1)
end)
test('snapshot pages replace atomically and malformed data changes nothing', function()
    local f = fixture(); f.api.receiveState(f:state(1)); f:tick()
    local one = f:snapshot(3, {}); one.snapshotId, one.slice, one.total = 'batch', 1, 2
    assert(f.api.receiveSnapshot(one)); assert(f.api.state(8))
    local two = f:snapshot(3, { f:state(2, 'local', 7) }); two.snapshotId, two.slice, two.total = 'batch', 2, 2
    assert(f.api.receiveSnapshot(two)); assert(not f.api.state(8) and f.api.state(7))
    local invalid = f:state(4, 'bad', 7, true, 'arbitrary')
    assert(not f.api.receiveSnapshot(f:snapshot(4, { invalid })))
    assert(f.api.state(7).playbackId == 'local')
end)
test('stream recreation reuses the same canonical action on the new body', function()
    local f = fixture(); f.api.receiveState(f:state(1)); f:tick()
    f.context.players[8] = nil; f:tick(); assert(f.calls[2][1] == 'stop')
    assert(f.api.state(8))
    f.context.players[8] = 81; f:tick()
    assert(f.calls[3][1] == 'play' and f.calls[3][2] == 81)
end)
test('server cycle edge explicitly restarts a repeated clip once', function()
    local f = fixture(); f.api.receiveState(f:state(1)); f:tick()
    local next = f:state(2); next.cycle = 1; f.api.receiveState(next); f:tick()
    assert(#f.calls == 2 and f.calls[2][5] == true)
    f:tick(); assert(#f.calls == 2)
end)
test('local animation uses player sentinel for the forced F7 native path', function()
    local f = fixture(); f.api.receiveState(f:state(1, 'local', 7)); f:tick()
    assert(f.calls[1][2] == 0)
    assert(f.api.cancel('local')); assert(f.calls[2][1] == 'stop' and f.calls[2][2] == 0)
    assert(f.sent[1][1] == 'stopRequest' and f.sent[1][3] == 'local')
    f:tick(); assert(#f.calls == 2)
end)
test('native failure cancels local authority and never starts it again', function()
    for _, reason in ipairs({ 'playback_timeout', 'interrupted', 'device_record_unavailable', 'mount_failed' }) do
        local f = fixture(); f.api.receiveState(f:state(1, 'local', 7)); f:tick()
        f.status = 'device_pending'; f:tick(); assert(#f.calls == 1)
        f.status = reason; f:tick()
        assert(f.calls[2][1] == 'stop' and f.sent[1][1] == 'stopRequest')
        local failed = f.events[#f.events]
        assert(failed[1] == 'onAnimationPlaybackFailed' and failed[2] == 7 and
            failed[3] == 'local' and failed[4] == reason)
        local eventCount = #f.events
        f:tick(); assert(#f.calls == 2 and #f.events == eventCount)
        -- A retained native terminal status must not flood callbacks or restart
        -- the same action, even after the next authoritative snapshot.
        f.api.receiveSnapshot(f:snapshot(2, { f:state(1, 'local', 7) }))
        eventCount = #f.events
        f:tick(); assert(#f.calls == 2 and #f.events == eventCount)
    end
end)
test('resource generation death cancels its accepted local action', function()
    local f = fixture(); local id = assert(f.api.request({ name = 'rp', generation = 2 }, 'smoke'))
    f.api.receiveResult({ requestId = id, ok = true, value = f:state(1, 'owned', 7) }); f:tick()
    f.alive = false; f:tick()
    assert(f.sent[#f.sent][1] == 'stopRequest' and f.sent[#f.sent][3] == 'owned')
end)
test('cancel before acknowledgement cancels late server acceptance', function()
    local f = fixture(); local id = assert(f.api.request({ name = 'rp' }, 'smoke'))
    assert(f.api.cancel())
    f.api.receiveResult({ requestId = id, ok = true, value = f:state(1, 'late', 7) })
    assert(f.sent[#f.sent][1] == 'stopRequest' and f.sent[#f.sent][3] == 'late')
end)
test('request timeout does not forget a potentially accepted action', function()
    local f = fixture(); local id = assert(f.api.request({ name = 'rp' }, 'smoke'))
    f.now = 11000; assert(f.api.result(id).error == 'request_timeout')
    f.api.receiveResult({ requestId = id, ok = true, value = f:state(1, 'late', 7) })
    assert(f.sent[#f.sent][3] == 'late')
end)

test('cancelled request never renders when broadcast precedes acknowledgement', function()
    for _, delivery in ipairs({ 'state', 'snapshot' }) do
        local f = fixture(); local id = assert(f.api.request({}, 'smoke'))
        assert(f.api.cancel()); assert(f.api.result(id).error == 'cancelled')
        local state = f:state(1, 'cancelled-before-state', 7); state.clientRequestId = id
        if delivery == 'state' then assert(f.api.receiveState(state))
        else assert(f.api.receiveSnapshot(f:snapshot(1, { state }))) end
        f:tick(); assert(#f.calls == 0, delivery .. ' must not start a cancelled local body')
        assert(f.sent[#f.sent][1] == 'stopRequest' and f.sent[#f.sent][3] == state.playbackId)
        f.api.receiveResult({ requestId = id, ok = true, value = state }); f:tick()
        assert(#f.calls == 0 and f.api.result(id).error == 'request_unavailable')
    end
end)

test('timeout and caller stop guard broadcast even before result polling', function()
    for _, reason in ipairs({ 'request_timeout', 'resource_stopped' }) do
        local f = fixture(); local id = assert(f.api.request({}, 'smoke'))
        if reason == 'request_timeout' then f.now = 10000 else f.alive = false end
        local state = f:state(1, 'abandoned', 7); state.clientRequestId = id
        assert(f.api.receiveState(state)); f:tick()
        assert(#f.calls == 0 and f.api.result(id).error == reason)
        assert(f.sent[2][1] == 'stopRequest' and f.sent[2][3] == state.playbackId)
    end
end)

test('pre-acknowledgement playback retains caller ownership and timeout', function()
    for _, reason in ipairs({ 'request_timeout', 'resource_stopped' }) do
        local f = fixture(); local id = assert(f.api.sequence({}, {}, {}))
        local state = f:state(1, 'pre-acknowledgement', 7); state.clientRequestId = id
        f.api.receiveState(state); f:tick(); assert(#f.calls == 1 and f.calls[1][2] == 0)
        if reason == 'request_timeout' then f.now = 10000 else f.alive = false end
        f:tick(); assert(#f.calls == 2 and f.calls[2][1] == 'stop')
        assert(f.api.result(id).error == reason and f.sent[#f.sent][3] == state.playbackId)
        f.api.receiveResult({ requestId = id, ok = true, value = state }); f:tick()
        assert(#f.calls == 2)
    end
end)

test('abandoned request does not block a different player or server-owned action', function()
    local f = fixture(); local id = assert(f.api.request({}, 'smoke')); f.api.cancel()
    local peer = f:state(1, 'remote', 8); peer.clientRequestId = id
    f.api.receiveState(peer); f:tick(); assert(#f.calls == 1 and f.calls[1][2] == 80)
    local other = f:state(2, 'server-action', 7); other.clientRequestId = ''
    f.api.receiveState(other); f:tick(); assert(#f.calls == 2 and f.calls[2][2] == 0)
    local late = f:state(1, 'old-abandoned', 7); late.clientRequestId = id
    f.api.receiveResult({ requestId = id, ok = true, value = late }); f:tick()
    assert(#f.calls == 2 and f.api.state().playbackId == 'server-action')
end)

test('late acceptance cannot clear cancellation of a replacement action', function()
    local f = fixture(); local id = assert(f.api.request({}, 'smoke')); f.api.cancel()
    local old = f:state(1, 'old', 7); old.clientRequestId = id
    f.api.receiveState(old); f:tick(); assert(#f.calls == 0)
    local newer = f:state(2, 'new', 7)
    f.api.receiveState(newer); f:tick(); assert(#f.calls == 1)
    f.api.cancel('new'); assert(#f.calls == 2)
    f.api.receiveResult({ requestId = id, ok = true, value = old }); f:tick()
    assert(#f.calls == 2, 'old reply must not unblock a newer cancelled playback')
end)

test('correlation is validated and replies cannot impersonate another request', function()
    local f = fixture(); local id = assert(f.api.request({}, 'smoke'))
    for _, invalid in ipairs({ true, 1, {}, string.rep('x', 65), 'nul\0id', string.rep('é', 33) }) do
        local state = f:state(1, 'invalid', 7); state.clientRequestId = invalid
        assert(not f.api.receiveState(state))
    end
    local state = f:state(1, 'wrong-request', 7); state.clientRequestId = 'another:request'
    f.api.receiveResult({ requestId = id, ok = true, value = state })
    assert(f.api.result(id).error == 'invalid_response' and not f.api.state())
end)

test('expired acceptance is cancelled even when result polling was suspended', function()
    local f = fixture(); local id = assert(f.api.request({}, 'smoke'))
    f.now = 10000
    local state = f:state(1, 'late', 7); state.clientRequestId = id
    f.api.receiveResult({ requestId = id, ok = true, value = state }); f:tick()
    assert(f.api.result(id).error == 'request_timeout' and #f.calls == 0)
    assert(f.sent[2][1] == 'stopRequest' and f.sent[2][3] == 'late')
end)
test('routing transition drops old-bucket actions and permits a fresh snapshot', function()
    local f = fixture(); local old = f:state(1); f.api.receiveState(old); f:tick()
    f.context = { ready = true, generation = 1, bucket = 42, playerId = 7, players = {} }; f:tick()
    assert(not f.api.state(8)); assert(not f.api.receiveState(old))
    assert(f.api.receiveSnapshot(f:snapshot(1, {})))
end)
test('queries are defensive copies and do not mutate the allowlist', function()
    local f = fixture(); local p = f.api.get('smoke'); p.clips[1] = 'bad'
    assert(f.api.get('smoke').clips[1] == 'smoke_a')
    assert(#f.api.list('SOCIAL') == 2)
    local list, err = f.api.list({}); assert(not list and err == 'invalid_query')
    assert(not f.api.request({}, 'unlisted'))
end)
test('disconnect retires local and remote bodies', function()
    local f = fixture(); f.api.receiveState(f:state(1)); f.api.receiveState(f:state(2, 'local', 7)); f:tick()
    f.context = { ready = false, generation = 2, bucket = 0, playerId = 0, players = {} }; f:tick()
    assert(#f.calls == 4 and not f.api.state(8))
end)
test('remote native failure retries on a new incarnation, not every tick', function()
    local f = fixture(); f.api.receiveState(f:state(1)); f:tick()
    f.status = 'detached'; f:tick(); f:tick(); assert(#f.calls == 2)
    f.context.players[8] = '18446744073709551601'; f.status = 'ok'; f:tick()
    assert(#f.calls == 3 and f.calls[3][2] == '18446744073709551601')
end)

test('stop acknowledgement and stale stop replies end retries', function()
    for _, err in ipairs({ 'success', 'stale_playback' }) do
        local f = fixture(); f.api.receiveState(f:state(1, 'local', 7)); f:tick(); f.api.cancel()
        local request = f.sent[#f.sent][2]
        f.api.receiveResult({ requestId = request, ok = err == 'success', error = err })
        f.now = 1200; f:tick(); assert(#f.sent == 1)
    end
end)

test('replacement stops retrying cancellation of an obsolete action', function()
    local f = fixture(); f.api.receiveState(f:state(1, 'old', 7)); f:tick(); f.api.cancel()
    f.api.receiveState(f:state(2, 'new', 7)); f.now = 1200; f:tick()
    assert(#f.sent == 1 and f.api.state().playbackId == 'new')
end)

test('cancellation resolves the caller immediately and rejects late presentation', function()
    local f = fixture(); local id = f.api.request({}, 'smoke'); f.api.cancel()
    assert(f.api.result(id).error == 'cancelled')
    f.api.receiveResult({ requestId = id, ok = true, value = f:state(1, 'late', 7) })
    f.api.receiveState(f:state(1, 'late', 7)); f:tick(); assert(#f.calls == 0)
end)

test('a result for another player or epoch cannot gain ownership', function()
    local f = fixture(); f.api.receiveSnapshot(f:snapshot(0, {}))
    local id = f.api.request({}, 'smoke')
    local wrong = f:state(1, 'wrong', 7); wrong.epoch = 'stale-epoch'
    f.api.receiveResult({ requestId = id, ok = true, value = wrong })
    assert(f.api.result(id).error == 'invalid_response' and not f.api.state())
    id = f.api.request({}, 'smoke')
    f.api.receiveResult({ requestId = id, ok = true, value = f:state(1, 'wrong', 8) })
    assert(f.api.result(id).error == 'invalid_response' and not f.api.state(8))
end)

test('pages cannot mix epochs and sparse snapshots cannot remove players', function()
    local f = fixture()
    local a = f:snapshot(1, {}); a.snapshotId, a.slice, a.total = 'same', 1, 2
    assert(f.api.receiveSnapshot(a))
    local b = f:snapshot(1, {}); b.snapshotId, b.slice, b.total, b.epoch = 'same', 2, 2, 'other'
    assert(not f.api.receiveSnapshot(b))
    f.api.receiveState(f:state(1)); f:tick()
    assert(not f.api.receiveSnapshot(f:snapshot(2, { bad = f:state(2) })))
    assert(f.api.state(8))
end)
test('maximum roster fits each scheduler resume budget', function()
    local f = fixture(); local maximum = 0
    for page = 1, 512 do
        local items = {}
        for index = 1, 8 do
            local player = (page - 1) * 8 + index
            local s = f:state(player, 'player-' .. player, player)
            s.clientRequestId = string.rep('x', 64)
            for step = 2, 16 do s.steps[step] = { profile = 'smoke', clip = 'smoke_a', durationMs = 1000 } end
            items[#items + 1] = s
        end
        local snapshot = f:snapshot(4096, items)
        snapshot.snapshotId, snapshot.slice, snapshot.total = 'full', page, 512
        local instructions = 0
        debug.sethook(function() instructions = instructions + 1000 end, '', 1000)
        local ok = f.api.receiveSnapshot(snapshot)
        debug.sethook()
        assert(ok); maximum = math.max(maximum, instructions)
    end
    print('RP maximum snapshot resume instructions: ' .. maximum)
    assert(maximum < 500000, 'snapshot exceeds ResourceHost instruction limit: ' .. maximum)
    assert(f.api.state(4096))
    local maximumTick = 0
    for _ = 1, 128 do
        local instructions = 0
        debug.sethook(function() instructions = instructions + 1000 end, '', 1000)
        f:tick()
        debug.sethook()
        maximumTick = math.max(maximumTick, instructions)
    end
    assert(#f.events == 4096, 'all snapshot notifications are eventually delivered')
    print('RP maximum roster tick instructions: ' .. maximumTick)
    assert(maximumTick < 500000, 'roster tick exceeds ResourceHost instruction limit: ' .. maximumTick)
end)
test('queued snapshot notifications cannot follow a newer live state', function()
    local f = fixture(); assert(f.api.receiveSnapshot(f:snapshot(1, { f:state(1) })))
    assert(#f.events == 0)
    f.api.receiveState(f:state(2, 'replacement')); f:tick()
    assert(#f.events == 1 and f.events[1][3].playbackId == 'replacement')
end)
test('pointing release cancels late start without stopping replacement', function()
    local f = fixture(true)
    local owner = { name = 'point_input', generation = 1 }
    local id = assert(f.api.requestPointing(owner))
    assert(f.api.stopPointing(owner))
    local late = f:state(1, 'late-point', 7)
    late.steps[1].profile, late.steps[1].clip = 'camera_point', 'camera_point'
    late.clientRequestId = id
    assert(f.api.receiveState(late)); f:tick()
    assert(not f.api.isPointing() and #f.calls == 0)
    assert(f.sent[#f.sent][1] == 'stopRequest')
    assert(f.api.receiveState(f:state(2, 'replacement', 7))); f:tick()
    local calls, sent = #f.calls, #f.sent
    assert(f.api.stopPointing(owner))
    assert(#f.calls == calls and #f.sent == sent)
end)

test('pointing stop is scoped to resource and generation', function()
    local f = fixture(true)
    local owner = { name = 'point_input', generation = 1 }
    local id = assert(f.api.requestPointing(owner))
    local s = f:state(1, 'point', 7)
    s.steps[1].profile, s.steps[1].clip = 'camera_point', 'camera_point'
    s.clientRequestId = id
    assert(f.api.receiveState(s)); f:tick()
    assert(f.api.isPointing())
    local before = #f.sent
    local again, error, current = f.api.requestPointing(owner)
    assert(not again and not error and current.playbackId == 'point' and #f.sent == before)
    local ok, err = f.api.stopPointing({ name = owner.name, generation = 2 })
    assert(not ok and err == 'not_owner' and f.api.isPointing())
    ok, err = f.api.stopPointing({ name = 'other', generation = 1 })
    assert(not ok and err == 'not_owner' and f.api.isPointing())
    assert(f.api.stopPointing(owner) and not f.api.isPointing())
    assert(f.calls[#f.calls][1] == 'stop')
end)

print(('RP animation controller: %d tests passed'):format(passed))
