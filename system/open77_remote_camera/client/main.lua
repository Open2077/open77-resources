-- One local source per server camera, with independent presentation bindings.
-- The server receives only presentation id, attempt, success and reason;
-- native source and binding handles remain local to this resource.
local R = Open77.remoteCamera

-- Bound native readiness wait; the server may retry with a new attempt id.
local ACK_TIMEOUT_MS = 3000

local sources = {}        -- server camera id -> { id = native camera id, pose = {...} }
local sinks = {}          -- presentation id -> sink record
local sinksByBinding = {} -- native binding id -> sink record

local function nowMs()
    return Open77.time.monotonic() * 1000.0
end

local function finite(value)
    return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function vector3(value, fields)
    if type(value) ~= "table" then return false end
    for _, field in ipairs(fields) do
        if not finite(value[field]) then return false end
    end
    return true
end

local function copy(value)
    local result = {}
    for key, item in next, value, nil do result[key] = item end
    return result
end

-- Prop ids are unsigned 64-bit decimals and arrive as strings (`Open77.props.get`
-- publishes them that way, and the native parent reader takes them back); they are
-- passed on exactly as received, never through a number. Player and vehicle ids are
-- numeric platform ids.
local MAX_UNSIGNED64 = "18446744073709551615"

local function validParentId(kind, id)
    if kind == "prop" then
        if type(id) ~= "string" or #id == 0 or #id > #MAX_UNSIGNED64 or id:match("^%d+$") == nil then
            return false
        end
        if id:sub(1, 1) == "0" then return false end
        if #id == #MAX_UNSIGNED64 then return id <= MAX_UNSIGNED64 end
        return true
    end
    return finite(id) and id > 0 and id % 1 == 0 and id <= 9007199254740991
end

local function validParent(value)
    return type(value) == "table"
        and (value.type == "prop" or value.type == "player" or value.type == "vehicle")
        and validParentId(value.type, value.id)
end

local function sameParent(a, b)
    if a == nil or b == nil then return a == b end
    return a.type == b.type and a.id == b.id
end

local function sameVector(a, b)
    if a == nil or b == nil then return a == b end
    for key, value in next, a, nil do
        if b[key] ~= value then return false end
    end
    for key in next, b, nil do
        if a[key] == nil then return false end
    end
    return true
end

local function report(id, attempt, ok, reason)
    TriggerServerEvent("open77:remoteCamera:present-result", id, attempt, ok == true,
        ok and nil or tostring(reason or "unknown"))
end

-- One answer per attempt: the first one wins and clears the debt, so a native
-- event that arrives after the watchdog already answered is not sent twice.
local function answer(sink, ok, reason)
    local pending = sink.pending
    if not pending then return end
    sink.pending = nil
    report(sink.id, pending.attempt, ok, reason)
end

local function poseOf(camera)
    return {
        position = { x = camera.position.x, y = camera.position.y, z = camera.position.z },
        rotation = { yaw = camera.rotation.yaw, pitch = camera.rotation.pitch,
            roll = camera.rotation.roll },
        fov = camera.fov, range = camera.range,
    }
end

local function samePose(pose, camera)
    return pose.fov == camera.fov and pose.range == camera.range
        and sameVector(pose.position, camera.position) and sameVector(pose.rotation, camera.rotation)
end

----------------------------------------------------------------------
-- Sources: one native camera per (server camera) on this client
----------------------------------------------------------------------

local function unused(cameraId)
    for _, sink in next, sinks, nil do
        if sink.cameraId == cameraId then return false end
    end
    return true
end

local function releaseSource(cameraId)
    local source = sources[cameraId]
    if not source then return end
    if not unused(cameraId) then return end
    sources[cameraId] = nil
    R.destroy(source.id)
end

local function ensureSource(cameraId, camera)
    local source = sources[cameraId]
    if source then
        if samePose(source.pose, camera) then return source end
        local ok, reason = R.update(source.id, poseOf(camera))
        if ok then
            source.pose = poseOf(camera)
            return source
        end
        -- The source can be retired under us (a host teardown, a resource
        -- reload). Rebuilding is the only honest recovery: a stale id would
        -- answer every future patch with the same refusal.
        sources[cameraId] = nil
        R.destroy(source.id)
    end
    local id, reason = R.create(poseOf(camera))
    if not id then return nil, reason end
    source = { id = id, pose = poseOf(camera) }
    sources[cameraId] = source
    return source
end

----------------------------------------------------------------------
-- Sinks: one native binding per presentation
----------------------------------------------------------------------

-- One transparent page hosts every WebUI view: `bindWebUI` draws the camera
-- image behind a rectangle of a resource-owned page, and this page paints
-- nothing at all, so the rectangle is the whole picture.
local underlayPage = nil
local function viewPage()
    if underlayPage then return underlayPage end
    local page, reason = Open77.webui.create({
        entry = "web/view.html", layer = "hud", width = 1920, height = 1080, transparent = true,
    })
    if not page then return nil, tostring(reason) end
    underlayPage = page
    return page
end

local function dropSink(id)
    local sink = sinks[id]
    if not sink then return end
    sinks[id] = nil
    if sink.binding then
        sinksByBinding[sink.binding] = nil
        R.unbind(sink.binding)
        sink.binding = nil
    end
    releaseSource(sink.cameraId)
end

-- The patch a binding needs to match the requested payload, or a rebuild when
-- the change is one `updateBinding` cannot express (a model cleared back to the
-- default, which a patch carrying no value cannot say).
local function planPatch(sink, payload, source)
    local patch = {}
    if sink.sourceId ~= source.id then patch.cameraId = source.id end
    if sink.kind == "view" then
        -- A different surface is a different native binding, which no patch can
        -- express: the caller asked for a HUD rectangle or for an underlay, and
        -- the honest answer is to build that one.
        if sink.applied.surface ~= nil and sink.applied.surface ~= payload.surface then
            return { rebuild = true }
        end
        local applied = sink.applied
        local rect = payload.rect
        for _, field in ipairs({ "x", "y", "width", "height" }) do
            if applied.rect == nil or applied.rect[field] ~= rect[field] then patch[field] = rect[field] end
        end
        if applied.visible == nil or applied.visible ~= payload.visible then
            patch.visible = payload.visible
        end
    else
        local applied = sink.applied.placement
        local placement = payload.placement
        if applied == nil then
            return { rebuild = true }
        end
        if applied.model ~= nil and placement.model == nil then return { rebuild = true } end
        if not sameParent(applied.parent, placement.parent) then
            -- Changing the frame requires the pose even when its numbers match.
            patch.position, patch.rotation = placement.position, placement.rotation
            if placement.parent == nil then patch.parent = false
            else patch.parent = { type = placement.parent.type, id = placement.parent.id } end
        end
        if not sameVector(applied.position, placement.position) then patch.position = placement.position end
        if not sameVector(applied.rotation, placement.rotation) then patch.rotation = placement.rotation end
        if applied.width ~= placement.width then patch.width = placement.width end
        if applied.height ~= placement.height then patch.height = placement.height end
        if applied.model ~= placement.model then patch.model = placement.model end
    end
    return patch
end

local function appliedFrom(sink, payload)
    if sink.kind == "view" then
        sink.applied = { rect = copy(payload.rect), visible = payload.visible, surface = payload.surface }
    else
        local placement = payload.placement
        sink.applied = { placement = {
            position = copy(placement.position), rotation = copy(placement.rotation),
            width = placement.width, height = placement.height, model = placement.model,
            parent = placement.parent and { type = placement.parent.type, id = placement.parent.id } or nil,
        } }
    end
end

-- Is the binding established? "hidden" is a binding that exists and is not drawn,
-- which is what a hidden HUD view is; "pending" and an unknown snapshot shape are
-- answered by the event handler or the watchdog instead of guessed at here.
local function confirm(sink)
    if not sink.pending or not sink.binding then return end
    local snapshot = R.getBinding(sink.binding)
    local state = type(snapshot) == "table" and snapshot.state or nil
    if state == "active" or state == "hidden" then
        answer(sink, true)
    elseif state == "failed" or state == "unavailable" then
        answer(sink, false, snapshot.reason)
    end
end

local function bind(sink, payload, source)
    local binding, reason
    if payload.kind == "view" then
        if payload.surface == "webui" then
            local page, pageReason = viewPage()
            if not page then return false, pageReason end
            binding, reason = R.bindWebUI(source.id, page, copy(payload.rect))
        else
            binding, reason = R.bindHud(source.id, copy(payload.rect))
        end
    else
        -- The placement is forwarded as authored: model is an alias the native
        -- side resolves to a validated profile, never a mesh name.
        binding, reason = R.bindWorld(source.id, copy(payload.placement))
    end
    if not binding then return false, reason end
    sink.binding = binding
    sinksByBinding[binding] = sink
    sink.sourceId = source.id
    appliedFrom(sink, payload)
    if payload.kind == "view" and payload.visible == false then
        local ok, refusal = R.updateBinding(binding, { visible = false })
        if not ok then
            dropSink(sink.id)
            return false, refusal
        end
        sink.applied.visible = false
    end
    return true
end

local function present(rawPayload)
    if not R then
        local id, attempt = tonumber(rawPayload.id), tonumber(rawPayload.attempt)
        if id and attempt then report(id, attempt, false, "remote_camera_unavailable") end
        return
    end

    local id, attempt = tonumber(rawPayload.id), tonumber(rawPayload.attempt)
    local cameraId = tonumber(rawPayload.cameraId)
    local kind = rawPayload.kind
    local camera = rawPayload.camera
    if not id or not attempt or not cameraId or (kind ~= "view" and kind ~= "screen")
        or type(camera) ~= "table" or not vector3(camera.position, { "x", "y", "z" })
        or not vector3(camera.rotation, { "yaw", "pitch", "roll" })
        or not finite(camera.fov) or not finite(camera.range) then
        if id and attempt then report(id, attempt, false, "invalid_presentation") end
        return
    end

    local payload = {
        id = id, attempt = attempt, kind = kind, cameraId = cameraId,
        camera = camera, rect = rawPayload.rect, visible = rawPayload.visible ~= false,
    }
    if kind == "view" then
        local surface = rawPayload.surface
        if surface == nil then surface = "hud" end
        if surface ~= "hud" and surface ~= "webui" then
            report(id, attempt, false, "invalid_view_surface")
            return
        end
        payload.surface = surface
        local rect = payload.rect
        if type(rect) ~= "table" or not vector3(rect, { "x", "y" })
            or not finite(rect.width) or rect.width <= 0
            or not finite(rect.height) or rect.height <= 0 then
            report(id, attempt, false, "invalid_rect")
            return
        end
        payload.rect = { x = rect.x, y = rect.y, width = rect.width, height = rect.height }
    else
        local placement = rawPayload.placement
        if type(placement) ~= "table" or not vector3(placement.position, { "x", "y", "z" })
            or not vector3(placement.rotation, { "yaw", "pitch", "roll" })
            or not finite(placement.width) or placement.width <= 0
            or not finite(placement.height) or placement.height <= 0
            or (placement.model ~= nil and type(placement.model) ~= "string")
            or (placement.parent ~= nil and not validParent(placement.parent)) then
            report(id, attempt, false, "invalid_placement")
            return
        end
        -- With a parent, position and rotation are the local offset the native
        -- binding resolves inside the parent's frame; without one they are the
        -- world pose. Both are forwarded exactly as authored.
        payload.placement = {
            position = placement.position, rotation = placement.rotation,
            width = placement.width, height = placement.height, model = placement.model,
            parent = placement.parent and { type = placement.parent.type, id = placement.parent.id } or nil,
        }
    end

    local sink = sinks[id]
    if sink and sink.kind ~= kind then
        -- The server never changes a presentation's kind; a mismatch is a stale
        -- or forged frame, and it is refused without touching the live binding.
        report(id, attempt, false, "kind_mismatch")
        return
    end
    if not sink then
        sink = { id = id, kind = kind, cameraId = cameraId, sourceId = nil,
            binding = nil, applied = {}, pending = nil }
        sinks[id] = sink
    end
    -- A newer attempt supersedes the old one: the server is only waiting on this
    -- one, so the previous debt is dropped rather than answered late.
    sink.pending = { attempt = attempt, deadline = nowMs() + ACK_TIMEOUT_MS }

    local source, reason = ensureSource(cameraId, camera)
    if not source then
        answer(sink, false, reason)
        return
    end
    local previousCamera = sink.cameraId
    sink.cameraId = cameraId
    -- The pair's source is only held while some sink names it, so a camera
    -- switch releases the old one before anything can fail on the new one.
    if previousCamera ~= nil and previousCamera ~= cameraId then releaseSource(previousCamera) end
    local patch
    if sink.binding == nil then
        patch = { rebuild = true }
    else
        patch = planPatch(sink, payload, source)
    end

    if patch.rebuild then
        if sink.binding then
            sinksByBinding[sink.binding] = nil
            R.unbind(sink.binding)
            sink.binding = nil
            sink.applied = {}
        end
        local ok, refusal = bind(sink, payload, source)
        if not ok then
            answer(sink, false, refusal)
            return
        end
    else
        local sparse = false
        for _ in next, patch, nil do sparse = true break end
        if sparse then
            local ok, refusal = R.updateBinding(sink.binding, patch)
            if not ok then
                -- The binding can be gone while the sink remembers it. One
                -- rebuild is allowed before the attempt is reported failed.
                sinksByBinding[sink.binding] = nil
                sink.binding = nil
                sink.applied = {}
                local rebuilt, rebuildReason = bind(sink, payload, source)
                if not rebuilt then
                    answer(sink, false, rebuildReason or refusal)
                    return
                end
            else
                appliedFrom(sink, payload)
                sink.sourceId = source.id
            end
        end
    end
    confirm(sink)
end

----------------------------------------------------------------------
-- Events
----------------------------------------------------------------------

RegisterNetEvent("open77:remoteCamera:present", function(payload)
    if type(payload) ~= "table" then return end
    present(payload)
end)

RegisterNetEvent("open77:remoteCamera:dismiss", function(id)
    id = tonumber(id)
    if id then dropSink(id) end
end)

-- The native side's own account of a binding. It settles the attempt in flight
-- when there is one; when there is none, a binding that failed or was retired
-- after it had been established is reported as lost so the server can ask again
-- -- nothing else about the record is changed, and the frame carries no
-- authority of its own.
AddEventHandler("open77:remoteCamera:bindingChanged", function(event, cameraId, state, reason)
    if type(event) ~= "table" then
        -- Defensive: a positional delivery of the same fields.
        if type(event) ~= "string" and type(event) ~= "number" then return end
        event = { bindingId = event, cameraId = cameraId, state = state, reason = reason }
    end
    local sink = sinksByBinding[event.bindingId]
    if not sink then return end
    local bindingState = event.state
    if bindingState == "active" or bindingState == "hidden" then
        answer(sink, true)
    elseif bindingState == "failed" or bindingState == "unavailable" then
        if sink.pending then
            answer(sink, false, event.reason)
        else
            TriggerServerEvent("open77:remoteCamera:present-lost", sink.id)
        end
    elseif bindingState == "removed" then
        dropSink(sink.id)
        TriggerServerEvent("open77:remoteCamera:present-lost", sink.id)
    end
end)

-- A binding that is never reported on is answered here rather than left to the
-- server's own timeout: the server's retry is a second question, and a client
-- that can answer the first should.
CreateThread(function()
    while true do
        Wait(250)
        local now = nowMs()
        for _, sink in next, sinks, nil do
            local pending = sink.pending
            if pending and now >= pending.deadline then
                local snapshot = sink.binding and R.getBinding(sink.binding) or nil
                local state = type(snapshot) == "table" and snapshot.state or nil
                if state == "active" or state == "hidden" then
                    answer(sink, true)
                elseif state == "failed" or state == "unavailable" then
                    answer(sink, false, snapshot.reason)
                else
                    answer(sink, false, "binding_timeout")
                end
            end
        end
    end
end)

AddEventHandler("onClientResourceStart", function(name)
    if name ~= GetCurrentResourceName() then return end
    -- Ask for the operator's capture budget rather than wait to be pushed: a
    -- client that connects mid-round, or reloads its resource, must end up on
    -- the same number as everyone else. The answer is a native frame that lands
    -- on the capture budget directly; no Lua here can raise it.
    TriggerServerEvent("open77:remoteCamera:policy-request")
    -- A reload took every presentation with it. The server has no way to see
    -- that -- it still holds the bindings it sent -- so say so, or the panels
    -- stay gone until the player walks out of the radius and back in.
    TriggerServerEvent("open77:remoteCamera:client-reset")
end)

AddEventHandler("onClientResourceStop", function(name)
    if name ~= GetCurrentResourceName() then return end
    for id in next, sinks, nil do dropSink(id) end
    for cameraId in next, sources, nil do
        R.destroy(sources[cameraId].id)
        sources[cameraId] = nil
    end
end)
