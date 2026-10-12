-- open77_sound -- play an audio file a resource ships, in 2D or in the world.
--
-- The model in one paragraph. This resource owns ONE hidden CEF surface running
-- Web Audio. A caller's `play` reads the caller's own declared file, hands the
-- bytes to that surface once (they are cached there by key), and asks it to
-- start a source node. Spatial sounds get a PannerNode; the listener transform
-- is pushed from `Open77.camera.view()` on this resource's own thread, and the
-- panner does the distance and the stereo image. Nothing per-frame passes
-- through Lua: the page interpolates between listener pushes itself.
--
-- What this is NOT is written down in wiki/sound.md and is worth reading before
-- using it: it is not Wwise, it does not touch the game's mix, and it does not
-- occlude through walls.

local page
local ready = false
local blocked = false

local sounds = {}            -- handle -> record
local byKey = {}             -- owner .. "\0" .. id -> handle
local ownerCounts = {}       -- owner -> live sound count
local ownerGenerations = {}  -- owner -> generation seen at the last call
local clipKeys = {}          -- "<source resource>/file" -> true once the page holds it
local nextHandle = 1
local spatialCount = 0
local nextOwnerSweep = 0

-- Caps. Each one is a real limit of the thing behind it, not a round number.
--
--   MAX_SOUNDS      24 concurrent HRTF panners is already a heavy mix on the
--                   audio thread, and an RP scene that wants more than 24
--                   simultaneous clips wants a different tool.
--   MAX_PER_OWNER   so one resource cannot spend the whole session budget.
--   MAX_CLIP_BYTES  the host's own `readPackedFile` ceiling. Base64 of 1 MiB is
--                   1.37 MiB, which still clears the 2 MiB JSON ceiling a
--                   `page:send` rides -- raising this cap breaks the transport
--                   before it breaks the mixer.
--   LISTENER_MS     `Open77.camera.view()` costs six RTTI lookups and up to six
--                   ExecuteFunction calls per call, on the game thread. 20 Hz
--                   is the compromise; the panner ramps between pushes so the
--                   image does not step.
local MAX_SOUNDS = 24
local MAX_PER_OWNER = 8
local MAX_CLIP_BYTES = 1024 * 1024
local LISTENER_MS = 50
local DEFAULT_MAX_DISTANCE = 40.0
local MAX_MAX_DISTANCE = 500.0

local MIME = {
    mp3 = "audio/mpeg",
    ogg = "audio/ogg",
    oga = "audio/ogg",
    opus = "audio/ogg",
    wav = "audio/wav",
    flac = "audio/flac",
    m4a = "audio/mp4",
    aac = "audio/aac",
    webm = "audio/webm",
}

local function finite(value)
    return type(value) == "number" and value == value and
        value > -math.huge and value < math.huge
end

-- `/` is allowed on purpose: the server twin defaults a sound's id to the file
-- path, so that the common case needs no id at all, and a path has slashes in
-- it. An id is only ever a key in this resource's own tables -- it is never
-- resolved against the filesystem -- so widening it costs nothing.
local function validId(value)
    return type(value) == "string" and #value > 0 and #value <= 240 and
        value:match("^[%w_:%-%./]+$") ~= nil
end

local function validResourceName(value)
    return type(value) == "string" and #value > 0 and #value <= 64 and
        value:match("^[%w_%-%.]+$") ~= nil
end

local function mimeFor(file)
    local extension = file:match("%.([%w]+)$")
    if not extension then return nil end
    return MIME[extension:lower()]
end

local function readPoint(value)
    if type(value) ~= "table" then return nil end
    local x, y, z = value.x or value[1], value.y or value[2], value.z or value[3]
    if not finite(x) or not finite(y) or not finite(z) then return nil end
    return { x = x, y = y, z = z }
end

local function send(event, payload)
    if page and ready then return page:send(event, payload) end
    return false
end

-- ---------------------------------------------------------------------------
-- Clip supply
-- ---------------------------------------------------------------------------

-- A sound has an OWNER and a SOURCE, and they are not always the same string.
-- The owner is who may stop it -- `cops` for a client-side play, `@server:cops`
-- for one the server asked for -- and the source is the resource whose file is
-- read, which is `cops` in both cases. Keying clips by the source rather than
-- the owner is also what lets both halves of one resource share a decode.
local function ownerResource(owner)
    return (owner:gsub("^@server:", ""))
end

-- The one place another resource's bytes are read, and the only reason this
-- resource asks for `resources.files.read`. `resource` is never taken from a
-- caller-supplied argument: on the export path it is GetInvokingResource(), on
-- the net path it is the name the server prelude stamped on the event.
local function ensureClip(resource, file)
    if type(file) ~= "string" or #file == 0 or #file > 240 then
        return nil, "invalid_file"
    end
    if file:find("%.%.") or file:find("^/") or file:find(":") then
        return nil, "invalid_file"
    end
    local mime = mimeFor(file)
    if not mime then return nil, "unsupported_audio_format" end

    local key = resource .. "/" .. file
    if clipKeys[key] then return key end

    local data, bytes = Open77.resource.readPackedFile(resource, file)
    if data == nil then
        -- `bytes` carries the reason when the read failed. The host's file
        -- errors carry the path after a colon, which is useful in a log and
        -- wrong in an API: a caller matching on a reason must not have to strip
        -- a filename off it first.
        local reason = tostring(bytes)
        if reason:find("^file_too_large") then return nil, "clip_too_large" end
        if reason:find(":") and not reason:find("^permission_denied:") then
            return nil, "file_unreadable"
        end
        return nil, reason
    end
    if bytes > MAX_CLIP_BYTES then return nil, "clip_too_large" end
    if not send("sound:clip", { key = key, mime = mime, data = data }) then
        return nil, "surface_unavailable"
    end
    clipKeys[key] = true
    return key
end

-- ---------------------------------------------------------------------------
-- Ownership
-- ---------------------------------------------------------------------------

local function forget(handle, notifyPage)
    local record = sounds[handle]
    if not record then return false end
    sounds[handle] = nil
    byKey[record.owner .. "\0" .. record.id] = nil
    ownerCounts[record.owner] = math.max(0, (ownerCounts[record.owner] or 1) - 1)
    if record.spatial then spatialCount = math.max(0, spatialCount - 1) end
    if notifyPage then send("sound:stop", { handle = handle }) end
    return true
end

local function stopOwner(owner)
    local removed = 0
    for handle, record in pairs(sounds) do
        if record.owner == owner then
            forget(handle, true)
            removed = removed + 1
        end
    end
    return removed
end

-- Everything an owner leaves behind: its live sounds AND its decoded clips. A
-- stopped resource's audio must not keep occupying the surface's cache budget,
-- and a RELOADED resource must not replay bytes from the file it used to ship.
local function releaseOwner(owner)
    local removed = stopOwner(owner)
    local prefix = ownerResource(owner) .. "/"
    for key in pairs(clipKeys) do
        if key:sub(1, #prefix) == prefix then
            send("sound:drop", { key = key })
            clipKeys[key] = nil
        end
    end
    return removed
end

-- A resource that stopped, or reloaded, must not leave a siren running, and the
-- thing that actually catches it is the SWEEP below -- not the stop event.
--
-- `onClientResourceStop` is dispatched to the stopping instance only
-- (DispatchToInstance in ResourceHost.cpp, not a broadcast), so this resource
-- never hears about anyone else's stop. The handler at the bottom keeps its
-- `else` branch because it costs nothing and is correct if that ever changes,
-- but it is the 250 ms sweep that ends an orphaned loop today. A quarter second
-- of siren after its owner died is the worst case, and it is bounded on purpose:
-- the sweep is two map lookups per tracked owner, so it is cheap enough to run
-- four times a second and never cheap enough to run every frame.
--
-- A reload is caught earlier still, by the generation check, which fires on the
-- caller's very next `play`.
local function invokingOwner()
    local owner = GetInvokingResource()
    local generation = GetInvokingResourceGeneration()
    if not validResourceName(owner) or type(generation) ~= "number" then
        return nil, "export_call_required"
    end
    if ownerGenerations[owner] ~= nil and ownerGenerations[owner] ~= generation then
        releaseOwner(owner)
    end
    ownerGenerations[owner] = generation
    return owner
end

local function sweepOwners()
    local now = Open77.time.monotonic()
    if now < nextOwnerSweep then return end
    nextOwnerSweep = now + 0.25
    for owner, generation in pairs(ownerGenerations) do
        if GetResourceState(owner) ~= "running" or
            Open77.resource.generation(owner) ~= generation then
            releaseOwner(owner)
            ownerGenerations[owner] = nil
        end
    end
end

-- ---------------------------------------------------------------------------
-- play / stop / setVolume / setPosition
-- ---------------------------------------------------------------------------

-- `owner` is who may stop it; `resource` is whose file is read. See the note on
-- ownerResource: a server-asked sound is owned by "@server:cops" and sourced
-- from "cops", and passing the owner where the source belongs would look for a
-- resource named "@server:cops" and fail with resource_not_found.
local function startSound(owner, resource, id, file, options)
    if not validResourceName(resource) then return nil, "resource_not_found" end
    if not validId(id) then return nil, "invalid_sound_id" end
    if options ~= nil and type(options) ~= "table" then return nil, "invalid_options" end
    options = options or {}
    if page == nil then return nil, "surface_unavailable" end
    if blocked then return nil, "audio_blocked" end

    local volume = options.volume
    if volume == nil then volume = 1.0 end
    if not finite(volume) or volume < 0.0 or volume > 1.0 then return nil, "invalid_volume" end

    local pitch = options.pitch
    if pitch == nil then pitch = 1.0 end
    if not finite(pitch) or pitch < 0.25 or pitch > 4.0 then return nil, "invalid_pitch" end

    local offset = options.offset
    if offset == nil then offset = 0.0 end
    if not finite(offset) or offset < 0.0 then return nil, "invalid_offset" end

    local loop = options.loop
    if loop == nil then loop = false end
    if type(loop) ~= "boolean" then return nil, "invalid_loop" end

    local maxDistance = options.maxDistance
    if maxDistance == nil then maxDistance = DEFAULT_MAX_DISTANCE end
    if not finite(maxDistance) or maxDistance <= 0.0 or maxDistance > MAX_MAX_DISTANCE then
        return nil, "invalid_max_distance"
    end
    local refDistance = options.refDistance
    if refDistance == nil then refDistance = 1.0 end
    if not finite(refDistance) or refDistance <= 0.0 or refDistance >= maxDistance then
        return nil, "invalid_ref_distance"
    end

    local position, entity
    if options.position ~= nil then
        position = readPoint(options.position)
        if not position then return nil, "invalid_position" end
    end
    if options.entity ~= nil then
        if position then return nil, "position_and_entity" end
        entity = options.entity
        if type(entity) ~= "number" and type(entity) ~= "string" then
            return nil, "invalid_entity"
        end
        local x, y, z = Open77.character.position(entity)
        if x == nil then return nil, "entity_not_found" end
        position = { x = x, y = y, z = z }
    end
    local spatial = position ~= nil

    local key, reason = ensureClip(resource, file)
    if not key then return nil, reason end

    -- Replacing the same id is a restart, not a second voice: an RP script that
    -- re-rings a doorbell expects one doorbell.
    local existing = byKey[owner .. "\0" .. id]
    if existing then forget(existing, true) end

    if (ownerCounts[owner] or 0) >= MAX_PER_OWNER then return nil, "owner_sound_limit" end
    local live = 0
    for _ in pairs(sounds) do live = live + 1 end
    if live >= MAX_SOUNDS then return nil, "sound_limit" end

    local handle = nextHandle
    nextHandle = nextHandle + 1
    sounds[handle] = {
        handle = handle, owner = owner, id = id, file = file, key = key,
        volume = volume, loop = loop, spatial = spatial, entity = entity,
        position = position, maxDistance = maxDistance,
    }
    byKey[owner .. "\0" .. id] = handle
    ownerCounts[owner] = (ownerCounts[owner] or 0) + 1
    if spatial then spatialCount = spatialCount + 1 end

    send("sound:play", {
        handle = handle, key = key, volume = volume, loop = loop, pitch = pitch,
        offset = offset, spatial = spatial, maxDistance = maxDistance,
        refDistance = refDistance,
        x = position and position.x or 0, y = position and position.y or 0,
        z = position and position.z or 0,
    })
    return id
end

local function stopSound(owner, id)
    if not validId(id) then return false, "invalid_sound_id" end
    local handle = byKey[owner .. "\0" .. id]
    if not handle then return false, "sound_not_found" end
    forget(handle, true)
    return true
end

local function setSoundVolume(owner, id, volume)
    if not validId(id) then return false, "invalid_sound_id" end
    if not finite(volume) or volume < 0.0 or volume > 1.0 then return false, "invalid_volume" end
    local handle = byKey[owner .. "\0" .. id]
    if not handle then return false, "sound_not_found" end
    sounds[handle].volume = volume
    send("sound:volume", { handle = handle, volume = volume })
    return true
end

local function setSoundPosition(owner, id, value)
    if not validId(id) then return false, "invalid_sound_id" end
    local point = readPoint(value)
    if not point then return false, "invalid_position" end
    local handle = byKey[owner .. "\0" .. id]
    if not handle then return false, "sound_not_found" end
    local record = sounds[handle]
    if not record.spatial then return false, "sound_not_spatial" end
    record.position = point
    record.entity = nil
    send("sound:positions", { items = { { handle = handle, x = point.x, y = point.y, z = point.z } } })
    return true
end

-- ---------------------------------------------------------------------------
-- Exports
-- ---------------------------------------------------------------------------

exports("play", function(id, file, options)
    local owner, reason = invokingOwner()
    if not owner then return nil, reason end
    return startSound(owner, owner, id, file, options)
end)

exports("stop", function(id)
    local owner, reason = invokingOwner()
    if not owner then return false, reason end
    return stopSound(owner, id)
end)

exports("stopAll", function()
    local owner, reason = invokingOwner()
    if not owner then return false, reason end
    -- Only the sounds: the clips stay cached, because a resource that stops
    -- everything is usually about to start something again.
    return stopOwner(owner)
end)

exports("setVolume", function(id, volume)
    local owner, reason = invokingOwner()
    if not owner then return false, reason end
    return setSoundVolume(owner, id, volume)
end)

exports("setPosition", function(id, position)
    local owner, reason = invokingOwner()
    if not owner then return false, reason end
    return setSoundPosition(owner, id, position)
end)

exports("isPlaying", function(id)
    local owner = invokingOwner()
    if not owner or not validId(id) then return false end
    return byKey[owner .. "\0" .. id] ~= nil
end)

exports("list", function()
    local owner = invokingOwner()
    if not owner then return {} end
    local result = {}
    for _, record in pairs(sounds) do
        if record.owner == owner then
            result[#result + 1] = {
                id = record.id, file = record.file, loop = record.loop,
                volume = record.volume, spatial = record.spatial,
            }
        end
    end
    table.sort(result, function(left, right) return left.id < right.id end)
    return result
end)

-- Decode ahead of the first play. Worth it for a sound whose first frame must
-- land on time -- a gunshot stinger, a door chime -- because the first play of
-- an unseen clip pays base64 transport plus decode.
exports("preload", function(file)
    local owner, reason = invokingOwner()
    if not owner then return false, reason end
    local key, why = ensureClip(owner, file)
    if not key then return false, why end
    return true
end)

-- ---------------------------------------------------------------------------
-- Server twin (`Open77.sound.*` in the server prelude)
-- ---------------------------------------------------------------------------
--
-- `open77:sound:` is a reserved TriggerClientEvent prefix, so the envelope's
-- `owner` was stamped by the prelude from GetCurrentResourceName() and cannot
-- be forged by a resource holding only `network.events`.

local function serverOwner(value)
    if not validResourceName(value) then return nil end
    return "@server:" .. value
end

RegisterNetEvent("open77:sound:play", function(envelope)
    if type(envelope) ~= "table" then return end
    local owner = serverOwner(envelope.owner)
    if not owner then return end
    -- The file belongs to the resource that asked, and that resource must exist
    -- on this client to ship it. A server-only resource has no client image.
    local id, reason = startSound(owner, envelope.owner, envelope.id, envelope.file, envelope.options)
    if not id then
        print("[open77_sound] server play refused (" .. tostring(envelope.owner) .. "/" ..
            tostring(envelope.file) .. "): " .. tostring(reason))
        TriggerEvent("open77:soundFailed", {
            owner = envelope.owner, id = envelope.id, file = envelope.file, reason = reason,
        })
    end
end)

RegisterNetEvent("open77:sound:stop", function(envelope)
    if type(envelope) ~= "table" then return end
    local owner = serverOwner(envelope.owner)
    if owner then stopSound(owner, envelope.id) end
end)

RegisterNetEvent("open77:sound:volume", function(envelope)
    if type(envelope) ~= "table" then return end
    local owner = serverOwner(envelope.owner)
    if owner then setSoundVolume(owner, envelope.id, envelope.volume) end
end)

RegisterNetEvent("open77:sound:position", function(envelope)
    if type(envelope) ~= "table" then return end
    local owner = serverOwner(envelope.owner)
    if owner then setSoundPosition(owner, envelope.id, envelope.position) end
end)

RegisterNetEvent("open77:sound:stopOwner", function(ownerName)
    local owner = serverOwner(ownerName)
    if owner then releaseOwner(owner) end
end)

-- ---------------------------------------------------------------------------
-- Surface lifecycle and the listener feed
-- ---------------------------------------------------------------------------

AddEventHandler("onClientResourceStart", function(name)
    if name ~= GetCurrentResourceName() then return end
    local reason
    page, reason = WebUI.create({
        entry = "web/index.html",
        layer = "hud",
        -- Nothing is ever drawn, so the surface is the smallest the host
        -- accepts and runs at the slowest frame rate it allows. `visible=false`
        -- calls WasHidden(true), which parks the compositor; the audio thread is
        -- clocked independently of it and is unaffected.
        width = 16, height = 16, fps = 1,
        zIndex = -1, transparent = true, visible = false,
    })
    if not page then
        print("[open77_sound] WebUI failed: " .. tostring(reason))
        return
    end
    page:on("sound:ready", function(payload)
        ready = true
        blocked = type(payload) == "table" and payload.blocked == true
        if blocked then
            print("[open77_sound] the browser refused to start audio " ..
                "(autoplay policy); every play will return audio_blocked")
        end
    end)
    page:on("sound:ended", function(payload)
        if type(payload) == "table" then forget(tonumber(payload.handle) or 0, false) end
    end)
    page:on("sound:evicted", function(payload)
        if type(payload) == "table" and type(payload.key) == "string" then
            clipKeys[payload.key] = nil
        end
    end)
    page:on("sound:error", function(payload)
        if type(payload) ~= "table" then return end
        local handle = tonumber(payload.handle)
        if handle then forget(handle, false) end
        print("[open77_sound] " .. tostring(payload.reason))
    end)

    CreateThread(function()
        while page do
            sweepOwners()
            if spatialCount > 0 and ready then
                local view = Open77.camera.view()
                if view then
                    send("sound:listener", {
                        x = view.position.x, y = view.position.y, z = view.position.z,
                        fx = view.forward.x, fy = view.forward.y, fz = view.forward.z,
                    })
                end
                -- Entity-attached sounds follow their body here rather than in
                -- the page, because only Lua can read a body's position.
                local items
                for handle, record in pairs(sounds) do
                    if record.entity ~= nil then
                        local x, y, z = Open77.character.position(record.entity)
                        if x == nil then
                            forget(handle, true)
                        else
                            record.position = { x = x, y = y, z = z }
                            items = items or {}
                            items[#items + 1] = { handle = handle, x = x, y = y, z = z }
                        end
                    end
                end
                if items then send("sound:positions", { items = items }) end
            end
            Wait(LISTENER_MS)
        end
    end)
end)

AddEventHandler("onClientResourceStop", function(name)
    if name == GetCurrentResourceName() then
        -- The surface dies with this resource, and with it the AudioContext and
        -- every source node hanging off it. Nothing outlives the stop.
        page, ready, blocked = nil, false, false
        sounds, byKey, ownerCounts, ownerGenerations, clipKeys = {}, {}, {}, {}, {}
        spatialCount = 0
    else
        -- Not reached today: the host dispatches this event to the stopping
        -- instance only. Kept because it is correct if that changes, and
        -- because it would end an orphan a quarter second earlier than the
        -- sweep does.
        releaseOwner(name)
        ownerGenerations[name] = nil
    end
end)
