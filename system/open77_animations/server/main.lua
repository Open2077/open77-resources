-- Optional player-facing entry point; all authoritative state stays in the
-- platform service. This command can only address its authenticated caller.
local lastRequest, lastSuggestion = {}, {}
local suggestions = { {
    command = '/anim', help = 'Open the animation menu. /anim stop cancels your current action.',
    parameters = { { name = 'profile|list|stop', help = 'Try smoke, dance, or handsup.' },
        { name = 'variant', help = 'Optional 1-based clip number from /anim info <profile>.' } },
} }
-- A command's reply. The server console runs commands as source 0, which is
-- not a chat target: answering it with `TriggerClientEvent` used to take the
-- whole resource down with an invalid envelope (2026-09-19, `/animprop` from
-- the Warden console stopped every animation on the server). The console reads
-- the log, so that is where its answer goes.
local function message(player, text)
    player = tonumber(player)
    if not player or player <= 0 then
        print('[open77_animations] ' .. tostring(text))
        return
    end
    TriggerClientEvent('chat:addMessage', player, {
        type = 'system', author = 'ANIMATIONS', text = text, color = { 0, 229, 255 },
    })
end
RegisterNetEvent('chat:ready', function()
    local player, now = source, Open77.time.monotonic()
    if lastSuggestion[player] and now - lastSuggestion[player] < 1 then return end
    lastSuggestion[player] = now
    TriggerClientEvent('chat:addSuggestions', player, suggestions)
end)
RegisterCommand('anim', function(player, args)
    if not player or player <= 0 then print('anim requires an authenticated player'); return end
    args = args or {}
    local action = args[1] or 'menu'
    local now = Open77.time.monotonic()
    if action ~= 'stop' and lastRequest[player] and now - lastRequest[player] < 0.5 then return end
    lastRequest[player] = now
    if action == 'menu' then
        -- A gamemode supplies the interface; the platform stays UI-independent.
        TriggerClientEvent('open77_animations:menu', player)
        return
    end
    if action == 'list' then
        local names = {}
        for _, p in ipairs(Open77.animations.list()) do names[#names + 1] = p.id end
        message(player, '/anim <profile> [variant] | /anim info <profile> | /anim stop\n' .. table.concat(names, ', '))
        return
    end
    if action == 'info' then
        local profile = Open77.animations.get(args[2] or '')
        if not profile then message(player, 'Unknown profile. Use /anim list.'); return end
        message(player, profile.label .. ' (' .. profile.category .. ')')
        for index, clip in ipairs(profile.clips) do message(player, tostring(index) .. ': ' .. clip) end
        return
    end
    if action == 'stop' then
        Open77.animations.stop(player) -- legacy command-owned action; no client round trip
        -- The subject may cancel their own action even when a UI/client resource
        -- started it. The controller sends the exact current playback ID.
        TriggerClientEvent('open77_animations:cancel', player)
        return
    end
    local profile = Open77.animations.get(action)
    if not profile then message(player, 'Unknown profile. Use /anim list.'); return end
    -- A gesture (`mode == "once"`: wave, shrug, point) plays a single time and
    -- ends `completed`; a hold or a workspot loops until /anim stop.
    local options = { loop = profile.mode ~= 'once' }
    if args[2] then
        local variant = tonumber(args[2])
        if not variant or variant ~= math.floor(variant) or not profile.clips[variant] then
            message(player, 'Invalid variant. Use /anim info ' .. profile.id .. '.'); return
        end
        options.clip = profile.clips[variant]
    end
    local state, err = Open77.animations.play(player, profile.id, options)
    if not state then message(player, 'Cannot play: ' .. tostring(err)) end
end, false)
-- Item lifetime is owned by the platform animation service. Native Items.*
-- attachments use the authored engine slot; jobs need no prop bookkeeping here.
AddEventHandler('onPlayerDisconnected', function(player)
    player = tonumber(player)
    if player then lastRequest[player], lastSuggestion[player] = nil, nil end
end)
