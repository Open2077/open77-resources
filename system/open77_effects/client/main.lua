-- Local effect helpers plus the projection client for the server-authoritative
-- effect registry. Attached effects retain desired state while bodies stream;
-- native particles themselves follow authored slots without transform packets.

-- A connected client can receive a newer resource generation before its native
-- plugin has been restarted. Stay inert on that transition instead of failing
-- the VM or exposing a half-wired effect layer.
if type(Open77.vfx) ~= "table" or type(Open77.vfx.play) ~= "function"
    or type(Open77.sfx) ~= "table" or type(Open77.sfx.play) ~= "function" then
    print("[open77_effects] native effects API unavailable; restart Cyberpunk to activate it")
    return
end

local function remember(handle)
    -- Native ownership already accounts for and releases every handle. Retaining
    -- expired one-shots in a Lua array would grow for the entire server session.
    return handle
end

exports("playVfx", function(effect, options)
    return remember(Open77.vfx.play(effect, options))
end)
exports("playEntityVfx", function(effect, options)
    return remember(Open77.vfx.playEntity(effect, options))
end)
exports("playSfx", function(event, options)
    return remember(Open77.sfx.play(event, options))
end)
exports("stop", function(handle) return Open77.vfx.stop(handle) end)
exports("attachVfx", function(handle, localEntity, slot)
    return Open77.vfx.attach(handle, localEntity, slot)
end)
exports("catalog", function() return Open77.vfx.catalog() end)

-- ---------------------------------------------------------------------------
-- Server-authoritative effects
-- ---------------------------------------------------------------------------

-- serverId -> native VFX handle for the looping effects the server owns.
local looping = {}
local loopingNames = {}
local attachedSounds = {}
local desired, projectedEntities, projectedBindings, seen, targetStates = {}, {}, {}, {}, {}
local epoch, snapshotFloor, pendingSnapshot, clockOffset = nil, 0, nil, nil
local incarnationCache = {}
local function nowMs() return Open77.time.monotonic() * 1000 end
local function key(id) return id ~= nil and tostring(id) or nil end
local function targetKey(target) return tostring(target.kind) .. ':' .. tostring(target.id) end
local function metadata(value)
    if value == nil then return epoch == nil end -- legacy world effects only
    if type(value) ~= 'table' or type(value.epoch) ~= 'string' or #value.epoch ~= 32
        or type(value.sequence) ~= 'number' or value.sequence < 1 or value.sequence % 1 ~= 0
        or value.sequence > 9007199254740991 or type(value.serverTime) ~= 'number'
        or value.serverTime < 0 or value.serverTime ~= value.serverTime or value.serverTime == math.huge then return false end
    if epoch and epoch ~= value.epoch then return false end
    epoch = value.epoch
    clockOffset = math.min(clockOffset or math.huge, nowMs() - value.serverTime)
    return true
end
local function expired(record)
    return type(record.expiresAt) == 'number' and clockOffset ~= nil
        and nowMs() - clockOffset >= record.expiresAt
end

RegisterNetEvent("open77:command:result", function(raw, accepted, message)
    if type(raw) ~= "string" or string.match(string.lower(raw), "^fx%.") == nil then return end
    print(string.format(
        "[server command] %s%s%s",
        accepted and "OK" or "ERR",
        raw ~= "" and (" " .. raw) or "",
        type(message) == "string" and message ~= "" and (": " .. message) or ""))
end)

-- A transform may arrive as { position = , orientation = , duration = } or as a
-- bare position; accept both rather than trusting one shape.
local function optionsFrom(transform, duration)
    local options = { duration = duration }
    if type(transform) ~= "table" then return options end
    if type(transform.position) == "table" then
        options.position = transform.position
    elseif transform.x ~= nil and transform.y ~= nil and transform.z ~= nil then
        options.position = { x = transform.x, y = transform.y, z = transform.z }
    end
    if type(transform.orientation) == "table" then options.orientation = transform.orientation end
    if transform.ignoreTimeDilation ~= nil then options.ignoreTimeDilation = transform.ignoreTimeDilation end
    if duration == nil and transform.duration ~= nil then options.duration = tonumber(transform.duration) end
    return options
end

-- Consume one-shot identities before target resolution: a dropped/off-stream
-- event must never become a deferred replay when a body appears later.
local soundActions = {}
local soundActionKeys, soundActionTimes = {}, {}
local soundActionHead, soundActionCount = 1, 0
local soundActionLimit = 8192
local function acceptSoundAction(id)
    if id == nil then return true end
    if type(id) ~= 'string' or #id ~= 64 or not id:match('^[0-9a-f]+$') then return false end
    local now = nowMs()
    while soundActionCount > 0 and now - soundActionTimes[soundActionHead] >= 60000 do
        soundActions[soundActionKeys[soundActionHead]] = nil
        soundActionKeys[soundActionHead], soundActionTimes[soundActionHead] = nil, nil
        soundActionHead = soundActionHead % soundActionLimit + 1
        soundActionCount = soundActionCount - 1
    end
    if soundActions[id] or soundActionCount >= soundActionLimit then return false end
    local slot = (soundActionHead + soundActionCount - 1) % soundActionLimit + 1
    soundActionKeys[slot], soundActionTimes[slot] = id, now
    soundActionCount = soundActionCount + 1
    soundActions[id] = true
    return true
end

-- Lifetime checks never wait for a target to stream. The only pending work is
-- a bounded cross-resource identity read for an already resolved local handle.
local pendingOneShots = {}
local function withOneShotTarget(target, play)
    if target == nil then play(nil); return end
    if type(target) ~= 'table' or type(Open77.vfx.resolveTarget) ~= 'function' then return end
    local entity = Open77.vfx.resolveTarget(target)
    if not entity then return end
    if target.lifetimeMode == nil or target.lifetimeMode == 'compatibility' then
        if target.incarnation ~= nil then return end
        play(entity); return
    end
    if target.lifetimeMode ~= 'cyberware' or target.kind ~= 'player'
        or type(target.incarnation) ~= 'string' or #target.incarnation ~= 42
        or not target.incarnation:match('^cyberware:[0-9a-f]+$') then return end
    if #pendingOneShots >= 256 or not Open77.exports or type(Open77.exports.call) ~= 'function' then return end
    local ok, promise = pcall(Open77.exports.call, 'open77_cyberware', 'incarnation', tostring(target.id))
    if not ok or not promise then return end
    pendingOneShots[#pendingOneShots+1] = {target=target,entity=entity,promise=promise,
        deadline=nowMs()+100,play=play}
end
local function pollOneShots()
    local pending = pendingOneShots
    pendingOneShots = {}
    for _, item in ipairs(pending) do
        if nowMs() < item.deadline and Open77.vfx.resolveTarget(item.target) == item.entity then
            local ok, status = pcall(function() return item.promise:status() end)
            if ok and status == 'pending' then
                pendingOneShots[#pendingOneShots+1] = item
            elseif ok and status == 'resolved' then
                -- Resolved-only await cannot suspend the effects scheduler.
                local read, binding = pcall(function() return item.promise:await() end)
                if read and binding == item.target.incarnation:sub(11) and nowMs() < item.deadline
                    and Open77.vfx.resolveTarget(item.target) == item.entity then item.play(item.entity) end
            end
        end
    end
end

-- Independent frame task: attachment polling sleeps 125 ms and may await a
-- resource export, which must not delay a one-shot's 100 ms identity deadline.
CreateThread(function()
    while true do
        if #pendingOneShots > 0 then pollOneShots() end
        Wait(0)
    end
end)

local function playSound(sound)
    if sound == nil then return end
    if type(sound) == "string" then
        remember(Open77.sfx.play(sound, {duration=5}))
        return
    end
    if type(sound) ~= "table" then return end
    -- D8: a voice-over line rides the sound slot with `voice` instead of
    -- `event`. It is resolved by the target's own voiceset, so it goes through
    -- Open77.sfx.playVoice (an entGameplayVOEvent on the body), never through
    -- the Wwise play below. Every viewer that has the body streamed plays it on
    -- its own puppet instance; one that does not resolves no target and drops it.
    if type(sound.voice) == "string" then
        if sound.entity ~= nil and sound.target == nil then return end
        withOneShotTarget(sound.target, function(entity)
            if entity == nil then return end
            local ok, reason = Open77.sfx.playVoice(sound.voice, {
                entity = entity, ignoreFrustum = sound.ignoreFrustum ~= false,
                ignoreDistance = sound.ignoreDistance == true,
            })
            if not ok then
                print(string.format("[open77_effects] voice %s rejected: %s", sound.voice, tostring(reason)))
            end
        end)
        return
    end
    if not acceptSoundAction(sound.actionId) then return end
    local event = sound.event or sound.name
    if type(event) ~= "string" then return end
    if sound.entity ~= nil and sound.target == nil then return end
    withOneShotTarget(sound.target, function(entity)
        remember(Open77.sfx.play(event, {
            entity=entity,emitter=sound.emitter,tag=sound.tag,seekTime=sound.seekTime,
            unique=sound.unique,duration=sound.duration or 5,
        }))
    end)
end

local function nameOf(record)
    -- The registry field is `effect`; `name` is accepted only so a record from an
    -- older server generation still projects instead of silently drawing nothing.
    local name = record.effect or record.name
    return type(name) == "string" and name or nil
end

local function stopVisual(id)
    id = key(id)
    local handle = looping[id]
    if handle == nil then return false end
    looping[id] = nil
    loopingNames[id] = nil
    projectedEntities[id] = nil
    projectedBindings[id] = nil
    Open77.vfx.stop(handle)
    return true
end

local function stopSound(id)
    local sound = attachedSounds[id]
    if sound then Open77.sfx.stop(sound.handle); attachedSounds[id] = nil end
end

local function stopLooping(id)
    id = key(id)
    stopSound(id)
    return stopVisual(id)
end

local function projectSound(id, record, entity, duration)
    local event = record.soundEvent
    local self = record.target.kind == 'player' and tostring(entity) == '1'
    if type(event) ~= 'string' or (self and record.soundOnOwner == false) then stopSound(id); return end
    local binding = targetKey(record.target) .. ':' .. record.target.incarnation
    local current = attachedSounds[id]
    if current and current.entity == entity and current.event == event and current.binding == binding then return end
    stopSound(id)
    local handle = Open77.sfx.play(event, {entity=entity,duration=duration})
    if handle then attachedSounds[id] = {handle=handle,entity=entity,event=event,binding=binding} end
end

local function projectLooping(record)
    if type(record) ~= "table" then return false end
    local id = key(record.id)
    local name = nameOf(record)
    if id == nil or name == nil then return false end
    if record.visible == false or expired(record) then stopLooping(id); return false end

    if record.target ~= nil then
        local target = record.target
        if type(target) ~= 'table' or type(target.incarnation) ~= 'string' then return false end
        local declared = targetStates[targetKey(target)]
        if not declared or declared.incarnation ~= target.incarnation then stopLooping(id); return false end
        if target.kind == 'player' and target.incarnation:sub(1,10) == 'cyberware:'
            and incarnationCache[tostring(target.id)] ~= target.incarnation:sub(11) then
            stopLooping(id); return false
        end
        local entity = Open77.vfx.resolveTarget(target)
        if not entity then stopLooping(id); return false end
        local binding = targetKey(target) .. ':' .. target.incarnation .. ':' .. tostring(record.slot)
            .. ':' .. tostring(record.localAnchor) .. ':' .. tostring(record.localSlot)
            .. ':' .. tostring(record.localEvent)
        local duration = math.min(600, math.max(.05, (record.expiresAt - (nowMs() - clockOffset)) / 1000))
        projectSound(id, record, entity, duration)
        if looping[id] and projectedEntities[id] == entity and loopingNames[id] == name
            and projectedBindings[id] == binding then return true end
        stopVisual(id)
        local handle
        local anchor, slot = 'body', record.slot
        local isSelf = target.kind == 'player' and tostring(entity) == '1'
        if isSelf then
            anchor, slot = record.localAnchor or 'body', record.localSlot or slot
        end
        if isSelf and type(record.localEvent) == 'string' then
            handle = Open77.vfx.playEntity(record.localEvent, {
                entity=entity, anchor=anchor, duration=duration,
                breakAllLoops=false, persistOnDetach=true,
            })
        else
            handle = Open77.vfx.play(name, {position={x=0,y=0,z=0}, duration=duration})
            if handle and not Open77.vfx.attach(handle, entity, slot, anchor) then
                Open77.vfx.stop(handle); return false
            end
        end
        if not handle then return false end
        looping[id], loopingNames[id], projectedEntities[id] = handle, name, entity
        projectedBindings[id] = binding
        return true
    end

    -- Position changes must preserve the live particle graph (and its trails).
    -- Only recreate after a changed effect or an expired/missing native handle.
    local existing = looping[id]
    if existing ~= nil and loopingNames[id] == name
        and type(Open77.vfx.update) == "function" then
        local moved, reason = Open77.vfx.update(existing, optionsFrom(record, nil))
        if moved then return true end
        if reason ~= "not_found" then
            print(string.format("[open77_effects] effect %s update rejected: %s", id, tostring(reason)))
            return false
        end
    end
    stopLooping(id)
    -- duration 0 keeps the handle until the server retires it or the resource
    -- is torn down; the registry, not the engine, decides when a loop ends.
    local handle, reason = Open77.vfx.play(name, optionsFrom(record, tonumber(record.duration) or 0))
    if handle == nil then
        print(string.format("[open77_effects] effect %s rejected: %s", id, tostring(reason)))
        return false
    end
    looping[id] = handle
    loopingNames[id] = name
    return true
end

RegisterNetEvent("open77:effects:oneshot", function(name, transform, sound)
    if type(name) == "string" then
        local target = type(transform) == "table" and transform.target or nil
        if not target and type(transform) == 'table' and transform.entity ~= nil then return end
        withOneShotTarget(target, function(entity)
        local handle, reason
        if entity ~= nil then
            if type(transform.slot) == "string" and transform.slot ~= "" then
                -- The world adapter requires an initial transform. Attachment
                -- replaces it synchronously before the next rendered frame.
                handle, reason = Open77.vfx.play(name, {
                    position = {x=0,y=0,z=0}, duration = transform.duration,
                })
                if handle then
                    local attached, why = Open77.vfx.attach(handle, entity, transform.slot)
                    if not attached then Open77.vfx.stop(handle); handle, reason = nil, why end
                end
            else
                handle, reason = Open77.vfx.playEntity(name, {
                    entity = entity,
                    duration = transform.duration,
                    breakAllLoops = transform.loop ~= true,
                })
            end
        else
            handle, reason = Open77.vfx.play(name, optionsFrom(transform, nil))
        end
        if handle == nil then
            print(string.format("[open77_effects] one-shot %s rejected: %s", name, tostring(reason)))
        else
            remember(handle)
        end
        end)
    end
    playSound(sound)
end)

RegisterNetEvent("open77:effects:upsert", function(record, meta)
    if not metadata(meta) or type(record) ~= 'table' then return false end
    local sequence = meta and meta.sequence or 0
    if type(record.targetState) == 'table' then
        local target = record.targetState
        if type(target.kind) ~= 'string' or type(target.incarnation) ~= 'string' or not target.id then return false end
        local tk = targetKey(target)
        if not targetStates[tk] or sequence > targetStates[tk].sequence then
            targetStates[tk] = {incarnation=target.incarnation, sequence=sequence}
        end
        return true
    end
    local id = key(record.id)
    if not id or (meta and sequence <= math.max(snapshotFloor, seen[id] or 0)) then return false end
    if record.target and (not meta or type(record.expiresAt) ~= 'number') then return false end
    seen[id], desired[id] = sequence, record
    return projectLooping(record)
end)

RegisterNetEvent("open77:effects:remove", function(id, reason, meta)
    if not metadata(meta) then return end
    id = key(id)
    if id == nil or (meta and meta.sequence <= math.max(snapshotFloor, seen[id] or 0)) then return end
    seen[id], desired[id] = meta and meta.sequence or 0, nil
    if stopLooping(id) then
        TriggerEvent("open77:effects:stopped", id, reason)
    end
end)

RegisterNetEvent("open77:effects:snapshot", function(snapshot, meta)
    if not metadata(meta) then return end
    if type(snapshot) ~= "table" then snapshot = {} end
    if meta then
        if meta.sequence <= snapshotFloor or type(meta.part) ~= 'number' or type(meta.total) ~= 'number'
            or meta.part % 1 ~= 0 or meta.total % 1 ~= 0 or meta.part < 1 or meta.part > meta.total
            or meta.total > 128 or #snapshot > 16 then return end
        if pendingSnapshot and meta.sequence < pendingSnapshot.sequence then return end
        if not pendingSnapshot or meta.sequence > pendingSnapshot.sequence then
            pendingSnapshot = {sequence=meta.sequence,total=meta.total,parts={},count=0}
        end
        local pending = pendingSnapshot
        if pending.total ~= meta.total or pending.parts[meta.part] then return end
        pending.parts[meta.part], pending.count = snapshot, pending.count + 1
        if pending.count ~= pending.total then return end
        snapshot = {}
        for _, part in ipairs(pending.parts) do for _, record in ipairs(part) do snapshot[#snapshot+1]=record end end
        pendingSnapshot = nil
    end

    local incoming = {}
    for _, record in ipairs(snapshot) do
        local id = type(record) == "table" and key(record.id) or nil
        if id ~= nil then incoming[id] = true end
    end

    local stale = {}
    for id in pairs(desired) do
        if not incoming[id] and (not meta or (seen[id] or 0) <= meta.sequence) then stale[#stale + 1] = id end
    end
    for _, id in ipairs(stale) do desired[id] = nil; stopLooping(id) end

    for _, record in ipairs(snapshot) do
        local id = key(record.id)
        if id and (not meta or (seen[id] or 0) <= meta.sequence) then
            if not record.target or (meta and type(record.expiresAt) == 'number') then
                desired[id], seen[id] = record, meta and meta.sequence or 0
                projectLooping(record)
            end
        end
    end
    if meta then
        snapshotFloor = meta.sequence
        for id, sequence in pairs(seen) do if not desired[id] and sequence <= snapshotFloor then seen[id] = nil end end
        local wanted = {}
        for _, record in pairs(desired) do if record.target then wanted[targetKey(record.target)] = true end end
        for tk, target in pairs(targetStates) do
            if not wanted[tk] and target.sequence <= snapshotFloor then targetStates[tk] = nil end
        end
    end
end)

local function stopEverything()
    pendingOneShots = {}
    for id in pairs(attachedSounds) do stopSound(id) end
    for id in pairs(looping) do stopLooping(id) end
    looping = {}
    loopingNames = {}
    desired, projectedEntities, projectedBindings, seen, targetStates, incarnationCache = {}, {}, {}, {}, {}, {}
    epoch, snapshotFloor, pendingSnapshot, clockOffset = nil, 0, nil, nil
    Open77.vfx.clear()
    Open77.sfx.clear()
end

AddEventHandler("onClientResourceStart", function(name)
    if name ~= GetCurrentResourceName() then return end
    stopEverything()
    TriggerServerEvent("open77:effects:ready")
end)

CreateThread(function()
    local polls = 0
    while true do
        local live = {}
        for _, item in ipairs(Open77.vfx.list() or {}) do live[tostring(item.id)] = true end
        local liveSounds = {}
        for _, item in ipairs(Open77.sfx.list() or {}) do liveSounds[tostring(item.id)] = true end
        local checked = {}
        for id, record in pairs(desired) do
            if record.target then
                local player = tostring(record.target.id)
                if record.target.incarnation:sub(1,10) == 'cyberware:' and not checked[player] then
                    checked[player] = true
                    incarnationCache[player] = nil
                    if Open77.exports and Open77.exports.call then
                        local promise = Open77.exports.call('open77_cyberware', 'incarnation', player)
                        if promise then
                            local ok, result = pcall(function() return promise:await() end)
                            if ok then incarnationCache[player] = result end
                        end
                    end
                end
                if desired[id] == record then
                    if looping[id] and not live[tostring(looping[id])] then stopVisual(id) end
                    if attachedSounds[id] and not liveSounds[tostring(attachedSounds[id].handle)] then
                        attachedSounds[id] = nil
                    end
                    projectLooping(record)
                end
            elseif expired(record) then stopLooping(id) end
        end
        polls = polls + 1
        if polls % 40 == 0 then TriggerServerEvent('open77:effects:ready') end
        Wait(125)
    end
end)

AddEventHandler("onClientResourceStop", function(name)
    if name ~= GetCurrentResourceName() then return end
    stopEverything()
end)

exports("looping", function()
    local result = {}
    for id, handle in pairs(looping) do result[#result + 1] = { id = id, handle = handle } end
    table.sort(result, function(a, b) return a.id < b.id end)
    return result
end)

-- ---------------------------------------------------------------------------
-- Local developer surface
-- ---------------------------------------------------------------------------

-- Dormant developer sampler. Nothing is spawned until a local debug resource
-- emits the event, and all handles are still owned/cleaned by this resource.
AddEventHandler("open77:effects:showcase", function()
    local state, reason = Open77.character.state()
    if not state then
        Open77.log.error("effects showcase: " .. tostring(reason))
        return
    end
    local p = state.position
    local samples = {
        { "smoke.steam", 3.0, 0.0, 12.0 },
        { "fire.small", 6.0, 0.0, 12.0 },
        { "electric.destruction", 9.0, 0.0, 5.0 },
    }
    for _, sample in ipairs(samples) do
        local handle, error = Open77.vfx.play(sample[1], {
            position = { x = p.x + sample[2], y = p.y + sample[3], z = p.z },
            duration = sample[4],
        })
        if handle then remember(handle)
        else Open77.log.warn(sample[1] .. ": " .. tostring(error)) end
    end
end)

AddEventHandler("open77:effects:clear", function()
    stopEverything()
end)

print("world effect projection ready")
