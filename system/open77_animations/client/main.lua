local native = Open77.animations
local resource = Open77.resource.name()
local generation = Open77.resource.generation()
local nonce = tostring(generation) .. ':' .. tostring(math.floor(Open77.time.monotonic() * 1000))
local running = true
local controller = RpAnimationController.new({
    now = function() return Open77.time.monotonic() * 1000 end,
    play = native._playProfile,
    stop = native.stop,
    status = native._profileStatus,
    send = function(name, ...) return TriggerServerEvent('open77:animations:' .. name, ...) end,
    emit = function(name, ...)
        if name == 'onAnimationPlaybackFailed' then
            local player, playback, reason = ...
            print(('RP playback failed: player=%s playback=%s reason=%s'):format(
                tostring(player), tostring(playback), tostring(reason)))
        end
        TriggerEvent(name, ...)
    end,
    ownerAlive = function(owner)
        return owner and Open77.resource.generation(owner.name) == owner.generation and
            GetResourceState(owner.name) == 'running'
    end,
}, RpAnimationCatalog, nonce)

-- Native transport rejects non-server sources for this reserved namespace;
-- local TriggerEvent cannot manufacture any of these authoritative messages.
RegisterNetEvent('open77:animations:state', controller.receiveState)
RegisterNetEvent('open77:animations:snapshot', controller.receiveSnapshot)
RegisterNetEvent('open77:animations:result', controller.receiveResult)
-- UI commands are ordinary resource events, not authoritative RP wire messages.
RegisterNetEvent('open77_animations:cancel', function() controller.cancel() end)

local function owner()
    return { name = GetInvokingResource() or resource,
        generation = GetInvokingResourceGeneration() or generation }
end
local function options(value, loop)
    if value ~= nil and type(value) ~= 'table' then return nil end
    local result = {}
    for k, v in pairs(value or {}) do result[k] = v end
    -- An empty Lua table serializes as []; the server expects an options object.
    if result.loop == nil then result.loop = loop end
    return result
end
local function awaitRequest(id, err)
    if not id then return nil, err end
    while running do
        local reply = controller.result(id)
        if reply then
            if reply.ok then return reply.value end
            return nil, reply.error
        end
        Wait(25)
    end
    return nil, 'resource_stopped'
end

exports('list', function(query) return controller.list(query, true) end)
exports('get', controller.get)
exports('clip', controller.clip)
exports('clips', function(query) return controller.clips(query, true) end)
exports('state', controller.state)
exports('cancel', controller.cancel)
exports('isPointing', controller.isPointing)
exports('setPointing', function(enabled)
    if type(enabled) ~= 'boolean' then return nil, 'invalid_enabled' end
    local capturedOwner = owner()
    if not enabled then return controller.stopPointing(capturedOwner) end
    local id, err, current = controller.requestPointing(capturedOwner)
    if current then return current end
    return awaitRequest(id, err)
end)
exports('request', function(profile, value)
    local opts = options(value, true)
    if not opts then return nil, 'invalid_options' end
    local capturedOwner = owner() -- invocation context is cleared across yields
    return awaitRequest(controller.request(capturedOwner, profile, opts))
end)
exports('requestClip', function(clip, value)
    local opts = options(value, true)
    if not opts then return nil, 'invalid_options' end
    local capturedOwner = owner()
    return awaitRequest(controller.requestClip(capturedOwner, clip, opts))
end)
exports('sequence', function(steps, value)
    local opts = options(value, false)
    if not opts then return nil, 'invalid_options' end
    local capturedOwner = owner()
    return awaitRequest(controller.sequence(capturedOwner, steps, opts))
end)

AddEventHandler('onClientResourceStop', function(name)
    if name == resource then running = false; controller.shutdown() end
end)
CreateThread(function()
    while running do
        local current = native._context()
        if current then controller.tick(current) end
        Wait(100)
    end
end)
