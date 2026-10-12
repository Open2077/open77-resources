-- Draft changes stay local; SAVE reconciles the placement with server records.
-- Server acceptance and native presentation readiness are separate states.

local RESOURCE = GetCurrentResourceName()
local RC = Open77.remoteCamera
local PAGE_ENTRY = "web/editor.html"
local SNAP_KEY = "remote-camera.editor.snap"
local SNAP_KEY_DEFAULT = "F4"
local AIM_DISTANCE = 150.0

-- Rebindable positioning modes update the local draft using gameplay controls.
local FOLLOW_KEY = "remote-camera.editor.follow"
local FOLLOW_KEY_DEFAULT = "F6"
local LIVESNAP_KEY = "remote-camera.editor.livesnap"
local LIVESNAP_KEY_DEFAULT = "F7"
local LIVE_INTERVAL = 0.033
-- Fallback catalogue until worldModels() is available. Apply each model's
-- yaw correction once when presenting, saving or exporting an authored pose.
local DEFAULT_MODELS = {
    { id = "surface", defaultWidth = 1.6, defaultHeight = 0.9, frameless = true,
      basis = { space = "entity_local", right = "+X", up = "+Z", normal = "-Y", yawOffset = 0 } },
    { id = "panel", defaultWidth = 1.6, defaultHeight = 0.9, frameless = false,
      basis = { space = "authored_mesh_face", normal = "mesh_face", yawOffset = 90 } },
}

local page, pageReady, pageReason = nil, false, nil
local pendingOpen = nil          -- server payload waiting for the page handshake
local session = nil              -- {token, bucket, editingKey}
local draft, baseDraft = nil, nil
local models = DEFAULT_MODELS
local aiming = false
local snapKey = SNAP_KEY_DEFAULT
local followKey, liveSnapKey = FOLLOW_KEY_DEFAULT, LIVESNAP_KEY_DEFAULT
local live = { follow = false, snap = false }

-- A local preview of the camera housing saved with the source. Standalone
-- props accept yaw only; the preview cannot match source pitch or roll.
local CAMERA_PROP_DEFAULT = "electronics.camera"
-- The housing hangs behind the lens, in the camera's own frame (+Y is forward).
-- A prop placed exactly at the pose films its own body: the mesh extends forward
-- from its origin, so the setback is what keeps the feed clear of it.
local CAMERA_PROP_OFFSET = { x = 0.0, y = -0.35, z = 0.0 }
local cameraProp = { id = nil, model = nil, pose = nil, saved = false }
local openDeadline = 0
local createAttempts, createRetryAt = 0, 0
local bindRetryAt = 0
local lastRefusal = nil

-- Preview objects and the values last accepted by them, so a patch carries only
-- what actually changed.
local preview = { camera = nil, feed = nil, world = nil, rect = nil, model = nil, suppressed = false }
local applied = { camera = {}, feed = {}, world = {} }
local pending = { camera = nil, feed = nil, world = nil }
local states = { source = { state = "none" }, feed = { state = "none" }, world = { state = "none" },
                 panel = { state = "none" }, budget = { state = "unknown" }, bucket = { state = "unknown" } }

-- Callbacks run after this chunk has initialized these local functions.
local stopSession, finishOpen, openEditor, refocus, performSnap

local function now() return Open77.time.monotonic() end
local function log(text) print("[remote-camera-editor] " .. tostring(text)) end
local function clamp(value, low, high) return math.min(high, math.max(low, value)) end
local function finite(value) return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge end
local function wrapDegrees(value) return (value + 180) % 360 - 180 end

local function modelRow(id)
    for _, row in ipairs(models) do
        if type(row) == "table" and row.id == id then return row end
    end
    for _, row in ipairs(DEFAULT_MODELS) do
        if row.id == id then return row end
    end
    return nil
end

-- Keep model-basis correction out of the draft to avoid accumulating offsets.
local function modelYawOffset(id)
    local row = modelRow(id)
    local basis = row and row.basis
    local offset = type(basis) == "table" and tonumber(basis.yawOffset) or nil
    if not finite(offset) then offset = (id == "panel") and 90 or 0 end
    return offset
end

local function appliedYaw(placement, model)
    return wrapDegrees(placement.rotation.yaw + modelYawOffset(model))
end

local function authoredYaw(storedYaw, model)
    return wrapDegrees(storedYaw - modelYawOffset(model))
end

-- Authored display dimensions for a model, so a new placement starts at the
-- size the model was built for instead of a number that happens to look right.
local function modelDefaults(id)
    local row = modelRow(id)
    local width = row and tonumber(row.defaultWidth) or nil
    local height = row and tonumber(row.defaultHeight) or nil
    if not finite(width) or width <= 0 then width = 1.6 end
    if not finite(height) or height <= 0 then height = 0.9 end
    return width, height
end

local function chatNotice(text)
    TriggerEvent("chat:addMessage", { author = "Remote Camera", text = tostring(text) })
end

local function send(name, payload)
    if page == nil or not pageReady then return false end
    local sent, reason = page:send(name, payload or {})
    if sent == false and lastRefusal ~= name then
        lastRefusal = name
        log("page refused the '" .. tostring(name) .. "' payload: " .. tostring(reason))
    end
    return sent ~= false
end

local function server(action, payload)
    payload = payload or {}
    payload.action = action
    payload.token = session and session.token or nil
    local ok, reason = TriggerServerEvent("open77:remoteCamera:editor:action", payload)
    if ok == false then
        send("editor:notice", { ok = false, message = "Editor message could not be sent: " .. tostring(reason) })
        return false
    end
    return true
end

-- ---------------------------------------------------------------------------
-- Draft shape and sanitising
-- ---------------------------------------------------------------------------

local function sanitizePose(raw)
    if type(raw) ~= "table" then return nil end
    local position, rotation = raw.position, raw.rotation
    if type(position) ~= "table" or type(rotation) ~= "table" then return nil end
    local values = { position = {}, rotation = {} }
    for _, axis in ipairs({ "x", "y", "z" }) do
        if not finite(position[axis]) or math.abs(position[axis]) > 1000000 then return nil end
        values.position[axis] = position[axis]
    end
    for _, axis in ipairs({ "yaw", "pitch", "roll" }) do
        local value = rotation[axis]
        if value == nil then value = 0 end
        if not finite(value) or math.abs(value) > 100000 then return nil end
        values.rotation[axis] = wrapDegrees(value)
    end
    return values
end

-- Canonical prop ids are decimal u64 strings; player/vehicle ids are numbers.
-- localProp names an owner-local allocation; entity names a raw engine object.
-- Neither client-only namespace may cross the server placement boundary.
local U64_MAX = "18446744073709551615"
local MAX_SAFE_INTEGER = 9007199254740991

-- Preserve uint64 integer bit patterns with %u; never round through a float.
local function engineIdText(value)
    local kind = type(value)
    if kind == "string" then
        if #value < 1 or #value > 32 then return nil end
        return value
    end
    if kind ~= "number" then return nil end
    if not finite(value) or value % 1 ~= 0 then return nil end
    local ok, text = pcall(string.format, "%u", value)
    if not ok or type(text) ~= "string" then return nil end
    return text
end

-- Canonical unsigned decimal identity, without leading zeros.
local function canonicalPropId(value)
    local id = engineIdText(value)
    if not id then return nil end
    if #id < 1 or #id > 20 or id:match("^[1-9]%d*$") == nil then return nil end
    if #id == 20 and id > U64_MAX then return nil end
    return id
end

local function sanitizeParent(raw)
    if type(raw) ~= "table" then return nil end
    local kind, id = raw.type, raw.id
    if kind == "prop" then
        -- On the wire a prop id is a string and a number is refused outright:
        -- a caller that already lost precision in a float must fail here rather
        -- than point the panel at a different prop.
        if type(id) ~= "string" then return nil end
        id = canonicalPropId(id)
        if not id then return nil end
        return { type = kind, id = id }
    end
    if kind == "player" or kind == "vehicle" then
        if type(id) ~= "number" or not finite(id) or id <= 0 or id % 1 ~= 0 or id > MAX_SAFE_INTEGER then return nil end
        return { type = kind, id = id }
    end
    if kind == "localProp" or kind == "entity" then
        -- A raw engine id: the platform's own lossless spelling (decimal or hex,
        -- or a signed integer normalised with %u), never a float.
        id = engineIdText(id)
        if type(id) ~= "string" or #id < 1 or #id > 32 or id:match("^[%w]+$") == nil then return nil end
        return { type = kind, id = id }
    end
    return nil
end

local function sanitizeAnchor(raw)
    if type(raw) ~= "table" or type(raw.position) ~= "table" or type(raw.normal) ~= "table" then return nil end
    local point, unit = raw.position, raw.normal
    if not (finite(point.x) and finite(point.y) and finite(point.z)) then return nil end
    if not (finite(unit.x) and finite(unit.y) and finite(unit.z)) then return nil end
    local length = math.sqrt(unit.x * unit.x + unit.y * unit.y + unit.z * unit.z)
    if length < 0.001 then return nil end
    return {
        position = { x = point.x, y = point.y, z = point.z },
        normal = { x = unit.x / length, y = unit.y / length, z = unit.z / length },
    }
end

-- The page is the editing surface, not an authority: everything it sends is
-- validated here before it touches a native object or the network. The server
-- validates the same payload again, because this validation protects this
-- client and not the server.
local function sanitizeHousing(raw)
    if type(raw) ~= "table" then return nil end
    local model = raw.model
    if type(model) ~= "string" or #model == 0 or #model > 64 or model:match("^[%w_%-%.:]+$") == nil then
        return nil
    end
    local offset = type(raw.offset) == "table" and raw.offset or CAMERA_PROP_OFFSET
    return {
        model = model,
        offset = {
            x = finite(offset.x) and clamp(offset.x, -10, 10) or 0,
            y = finite(offset.y) and clamp(offset.y, -10, 10) or 0,
            z = finite(offset.z) and clamp(offset.z, -10, 10) or 0,
        },
        yaw = finite(raw.yaw) and clamp(raw.yaw, -360, 360) or 0,
    }
end

local function sanitizeDraft(raw)
    if type(raw) ~= "table" then return nil, "invalid_draft" end
    local camera = sanitizePose(raw.camera)
    if not camera then return nil, "invalid_camera" end
    camera.fov = finite(raw.camera.fov) and clamp(raw.camera.fov, 1, 120) or 60
    camera.range = finite(raw.camera.range) and clamp(raw.camera.range, 1, 500) or 100
    local placement = sanitizePose(raw.placement)
    if not placement then return nil, "invalid_placement" end
    return {
        key = type(raw.key) == "string" and raw.key:match("^[%w%._%-]+$") and raw.key:sub(1, 48) or nil,
        name = type(raw.name) == "string" and raw.name:sub(1, 48) or "",
        model = (raw.model == "panel") and "panel" or "surface",
        cameraKey = type(raw.cameraKey) == "string" and raw.cameraKey:match("^[%w%._%-]+$") and raw.cameraKey:sub(1, 48) or nil,
        camera = camera,
        placement = {
            position = placement.position,
            rotation = placement.rotation,
            width = finite(raw.placement.width) and clamp(raw.placement.width, 0.05, 40) or 2.4,
            height = finite(raw.placement.height) and clamp(raw.placement.height, 0.05, 40) or 1.35,
            radius = finite(raw.placement.radius) and clamp(raw.placement.radius, 1, 500) or 40,
            access = raw.placement.access == "public" and "public" or "granted",
            parent = sanitizeParent(raw.placement.parent),
        },
        depth = finite(raw.depth) and clamp(raw.depth, -1, 5) or 0.02,
        anchor = sanitizeAnchor(raw.anchor),
        -- The visible housing the service will put on the wall, authored here and
        -- saved with the placement; nil means the camera stays invisible.
        housing = sanitizeHousing(raw.housing),
    }
end

local function copyDraft(source)
    local copy = {
        key = source.key, name = source.name, model = source.model, cameraKey = source.cameraKey,
        lastParent = source.lastParent,
        housing = source.housing and {
            model = source.housing.model,
            offset = { x = source.housing.offset.x, y = source.housing.offset.y, z = source.housing.offset.z },
            yaw = source.housing.yaw,
        } or nil,
        camera = {
            position = { x = source.camera.position.x, y = source.camera.position.y, z = source.camera.position.z },
            rotation = { yaw = source.camera.rotation.yaw, pitch = source.camera.rotation.pitch, roll = source.camera.rotation.roll },
            fov = source.camera.fov, range = source.camera.range,
        },
        placement = {
            position = { x = source.placement.position.x, y = source.placement.position.y, z = source.placement.position.z },
            rotation = { yaw = source.placement.rotation.yaw, pitch = source.placement.rotation.pitch, roll = source.placement.rotation.roll },
            width = source.placement.width, height = source.placement.height,
            radius = source.placement.radius, access = source.placement.access,
            parent = source.placement.parent and { type = source.placement.parent.type, id = source.placement.parent.id } or nil,
        },
        depth = source.depth,
        anchor = source.anchor and {
            position = { x = source.anchor.position.x, y = source.anchor.position.y, z = source.anchor.position.z },
            normal = { x = source.anchor.normal.x, y = source.anchor.normal.y, z = source.anchor.normal.z },
        } or nil,
    }
    return copy
end

-- ---------------------------------------------------------------------------
-- Player view helpers
-- ---------------------------------------------------------------------------

local function playerView()
    local view = Open77.camera.view()
    if view and view.position and view.forward then
        local f = view.forward
        return {
            position = { x = view.position.x, y = view.position.y, z = view.position.z },
            rotation = {
                yaw = math.deg(math.atan(-f.x, f.y)),
                pitch = math.deg(math.asin(clamp(f.z, -1, 1))),
                roll = 0,
            },
            fov = finite(view.fov) and clamp(view.fov, 1, 120) or 60,
            range = 100,
        }
    end
    local state = Open77.character.state()
    if state and state.position then
        local yaw = 0
        if state.forward then yaw = math.deg(math.atan(-state.forward.x, state.forward.y)) end
        return { position = { x = state.position.x, y = state.position.y, z = state.position.z },
                 rotation = { yaw = yaw, pitch = 0, roll = 0 }, fov = 60, range = 100 }
    end
    return nil, "player_view_unavailable"
end

local function forwardOf(rotation)
    local yaw, pitch = math.rad(rotation.yaw), math.rad(rotation.pitch)
    return { x = -math.sin(yaw) * math.cos(pitch), y = math.cos(yaw) * math.cos(pitch), z = math.sin(pitch) }
end

local function defaultPlacement(camera, model)
    local f = forwardOf(camera.rotation)
    local width, height = modelDefaults(model)
    -- The surface's front normal is its local -Y, so a display that faces the
    -- player is the one whose own yaw matches the camera's: its +Y points away
    -- from the camera, along the view, and its front points back down the view.
    return {
        position = { x = camera.position.x + f.x * 3.5, y = camera.position.y + f.y * 3.5, z = camera.position.z + f.z * 3.5 },
        rotation = { yaw = camera.rotation.yaw, pitch = 0, roll = 0 },
        width = width, height = height, radius = 40, access = "granted", parent = nil,
    }
end

local function newDraft()
    local camera, reason = playerView()
    if not camera then return nil, reason end
    local model = models[1] and models[1].id or "surface"
    return {
        key = nil, name = "", model = model, cameraKey = nil,
        camera = camera, placement = defaultPlacement(camera, model), depth = 0.02, anchor = nil,
    }
end

-- ---------------------------------------------------------------------------
-- Parent identity and frame selectors
-- ---------------------------------------------------------------------------
-- Resolve each parent in its own namespace. A canonical target that disappears
-- must not fall back to a cached engine identity.

local function parentSelector(parent)
    if type(parent) ~= "table" then return nil, "no_parent" end
    local kind = parent.type
    if kind == "player" or kind == "vehicle" then
        local id = parent.id
        if type(id) ~= "number" or not finite(id) or id <= 0 or id % 1 ~= 0 then return nil, "invalid_parent_id" end
        return kind == "player" and { playerId = id } or { vehicleId = id }
    end
    if kind == "prop" then
        local id = canonicalPropId(parent.id)
        if not id then return nil, "invalid_prop_id" end
        return { propId = id }
    end
    if kind == "entity" then
        local id = engineIdText(parent.id)
        if not id then return nil, "invalid_engine_id" end
        return { engineEntity = id, radius = 2.0 }
    end
    return nil, "parent_frame_unresolved:" .. tostring(kind)
end

local function parentFromHit(entity)
    if type(entity) ~= "table" then return nil end
    if entity.playerId then return { type = "player", id = entity.playerId } end
    if entity.vehicleId then return { type = "vehicle", id = entity.vehicleId } end
    if entity.propId ~= nil then
        -- A canonical Open77 prop identity, when the platform resolves one for
        -- this hit: the service can follow it, so it wins over the raw engine
        -- identity below. Only a canonical u64 decimal is one.
        local propId = canonicalPropId(entity.propId)
        if propId then return { type = "prop", id = propId } end
    end
    if entity.engineEntity ~= nil then
        -- Local scenery: the preview follows this client's own copy of it under
        -- the engine identity, which is the `entity` namespace and not a prop id.
        local engineId = engineIdText(entity.engineEntity)
        if engineId then return { type = "entity", id = engineId } end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Frames
-- ---------------------------------------------------------------------------
-- One selector, one resolution attempt. The platform's own reason is what the
-- caller reports, so a parent that has gone away reads as gone rather than as a
-- quietly different pose.
local function frameOf(selector)
    local frame, reason = Open77.character.frame(selector)
    if not frame then return nil, tostring(reason or "entity_frame_unavailable") end
    return frame
end

local function offsetToWorldOf(selector, point)
    local world, reason = Open77.character.offsetToWorld(selector, point)
    if not world then return nil, tostring(reason or "entity_position_unavailable") end
    return world
end

local function worldToOffsetOf(selector, point)
    local offset, reason = Open77.character.worldToOffset(selector, point)
    if not offset then return nil, tostring(reason or "entity_position_unavailable") end
    return offset
end

-- --- orientation -----------------------------------------------------------
-- Match native TransformOf: Qz(yaw) * Qx(pitch) * Qy(roll), {i,j,k,r}.

local function quaternionMultiply(left, right)
    return {
        i = left.r * right.i + left.i * right.r + left.j * right.k - left.k * right.j,
        j = left.r * right.j - left.i * right.k + left.j * right.r + left.k * right.i,
        k = left.r * right.k + left.i * right.j - left.j * right.i + left.k * right.r,
        r = left.r * right.r - left.i * right.i - left.j * right.j - left.k * right.k,
    }
end

local function quaternionConjugate(q)
    return { i = -q.i, j = -q.j, k = -q.k, r = q.r }
end

local function quaternionOf(rotation)
    local halfYaw = math.rad(rotation.yaw or 0) * 0.5
    local halfPitch = math.rad(rotation.pitch or 0) * 0.5
    local halfRoll = math.rad(rotation.roll or 0) * 0.5
    local yaw = { i = 0, j = 0, k = math.sin(halfYaw), r = math.cos(halfYaw) }
    local pitch = { i = math.sin(halfPitch), j = 0, k = 0, r = math.cos(halfPitch) }
    local roll = { i = 0, j = math.sin(halfRoll), k = 0, r = math.cos(halfRoll) }
    return quaternionMultiply(quaternionMultiply(yaw, pitch), roll)
end

-- Invert the native composition for parent-local conversion and detachment.
local function rotationOfQuaternion(q)
    local length = math.sqrt(q.i * q.i + q.j * q.j + q.k * q.k + q.r * q.r)
    if not finite(length) or length < 0.1 then return { yaw = 0, pitch = 0, roll = 0 } end
    local i, j, k, r = q.i / length, q.j / length, q.k / length, q.r / length
    return {
        yaw = math.deg(math.atan(2 * (r * k - i * j), 1 - 2 * (i * i + k * k))),
        pitch = math.deg(math.asin(clamp(2 * (r * i + j * k), -1, 1))),
        roll = math.deg(math.atan(2 * (r * j - i * k), 1 - 2 * (i * i + j * j))),
    }
end

-- The engine's own basis columns are the images of the entity's local X, Y and Z.
local function quaternionOfFrame(frame)
    local forward, right, up = frame.forward, frame.right, frame.up
    if type(forward) ~= "table" or type(right) ~= "table" or type(up) ~= "table" then return nil end
    for _, axis in ipairs({ forward, right, up }) do
        if not (finite(axis.x) and finite(axis.y) and finite(axis.z)) then return nil end
    end
    local r11, r12, r13 = right.x, forward.x, up.x
    local r21, r22, r23 = right.y, forward.y, up.y
    local r31, r32, r33 = right.z, forward.z, up.z
    local trace = r11 + r22 + r33
    local q
    if trace > 0 then
        local s = math.sqrt(trace + 1) * 2
        q = { r = 0.25 * s, i = (r32 - r23) / s, j = (r13 - r31) / s, k = (r21 - r12) / s }
    elseif r11 > r22 and r11 > r33 then
        local s = math.sqrt(1 + r11 - r22 - r33) * 2
        q = { r = (r32 - r23) / s, i = 0.25 * s, j = (r12 + r21) / s, k = (r13 + r31) / s }
    elseif r22 > r33 then
        local s = math.sqrt(1 + r22 - r11 - r33) * 2
        q = { r = (r13 - r31) / s, i = (r12 + r21) / s, j = 0.25 * s, k = (r23 + r32) / s }
    else
        local s = math.sqrt(1 + r33 - r11 - r22) * 2
        q = { r = (r21 - r12) / s, i = (r13 + r31) / s, j = (r23 + r32) / s, k = 0.25 * s }
    end
    local length = math.sqrt(q.i * q.i + q.j * q.j + q.k * q.k + q.r * q.r)
    if not finite(length) or length < 0.1 then return nil end
    return q
end

local function framePosition(frame)
    local position = frame.position
    if type(position) == "table" and finite(position.x) and finite(position.y) and finite(position.z) then return position end
    return nil
end

-- Used only when the engine's own offset natives are unavailable: the frame
-- columns carry the same composition.
local function frameOffsetToWorld(frame, offset)
    local base = framePosition(frame)
    if not base then return nil end
    return {
        x = base.x + frame.right.x * offset.x + frame.forward.x * offset.y + frame.up.x * offset.z,
        y = base.y + frame.right.y * offset.x + frame.forward.y * offset.y + frame.up.y * offset.z,
        z = base.z + frame.right.z * offset.x + frame.forward.z * offset.y + frame.up.z * offset.z,
    }
end

local function frameWorldToOffset(frame, point)
    local base = framePosition(frame)
    if not base then return nil end
    local dx, dy, dz = point.x - base.x, point.y - base.y, point.z - base.z
    return {
        x = frame.right.x * dx + frame.right.y * dy + frame.right.z * dz,
        y = frame.forward.x * dx + frame.forward.y * dy + frame.forward.z * dz,
        z = frame.up.x * dx + frame.up.y * dy + frame.up.z * dz,
    }
end

-- World pose -> the parent's own frame, position and orientation together. A
-- frame the platform cannot report is a refusal, never a heading-only guess: a
-- banked car would silently misplace and mis-rotate the panel.
local function toParentLocal(selector, world)
    local frame, frameReason = frameOf(selector)
    if not frame then return nil, frameReason end
    local parentQuaternion = quaternionOfFrame(frame)
    if not parentQuaternion then return nil, "entity_orientation_unavailable" end
    local position, positionReason = worldToOffsetOf(selector, world.position)
    if not position then position = frameWorldToOffset(frame, world.position) end
    if not position then return nil, positionReason end
    local orientation = rotationOfQuaternion(
        quaternionMultiply(quaternionConjugate(parentQuaternion), quaternionOf(world.rotation)))
    return { position = { x = position.x, y = position.y, z = position.z }, rotation = orientation }
end

local function fromParentLocal(selector, localPose)
    local frame, frameReason = frameOf(selector)
    if not frame then return nil, frameReason end
    local parentQuaternion = quaternionOfFrame(frame)
    if not parentQuaternion then return nil, "entity_orientation_unavailable" end
    local point, positionReason = offsetToWorldOf(selector, localPose.position)
    if not point then point = frameOffsetToWorld(frame, localPose.position) end
    if not point then return nil, positionReason end
    local orientation = rotationOfQuaternion(
        quaternionMultiply(parentQuaternion, quaternionOf(localPose.rotation)))
    return { position = { x = point.x, y = point.y, z = point.z }, rotation = orientation }
end

-- The pose a service record means by this placement: the model's authored pose
-- (its basis folded into the local orientation, exactly once) and then the
-- parent's own full frame.
local function localPoseOf(placement, model)
    return {
        position = placement.position,
        rotation = {
            yaw = appliedYaw(placement, model),
            pitch = placement.rotation.pitch,
            roll = placement.rotation.roll,
        },
    }
end

local function worldPose(placement, model)
    local localPose = localPoseOf(placement, model)
    if placement.parent == nil then return localPose end
    local selector, reason = parentSelector(placement.parent)
    if not selector then return nil, reason end
    return fromParentLocal(selector, localPose)
end

-- ---------------------------------------------------------------------------
-- Preview objects
-- ---------------------------------------------------------------------------

local function viewOf(camera)
    return {
        position = { x = camera.position.x, y = camera.position.y, z = camera.position.z },
        rotation = { yaw = camera.rotation.yaw, pitch = camera.rotation.pitch, roll = camera.rotation.roll },
        fov = camera.fov, range = camera.range,
    }
end

local function worldPlacementOf(placement, model)
    local out = {
        position = { x = placement.position.x, y = placement.position.y, z = placement.position.z },
        rotation = { yaw = appliedYaw(placement, model), pitch = placement.rotation.pitch, roll = placement.rotation.roll },
        width = placement.width, height = placement.height, model = model,
    }
    if placement.parent then out.parent = { type = placement.parent.type, id = placement.parent.id } end
    return out
end

local function reportState(channel, state, reason, extra)
    local next_state = { state = state, reason = reason }
    if type(extra) == "table" then
        for key, value in pairs(extra) do next_state[key] = value end
    end
    local current = states[channel] or {}
    if current.state == next_state.state and current.reason == next_state.reason and current.detail == next_state.detail then
        return
    end
    states[channel] = next_state
    if session then send("editor:states", states) end
end

local function stopPreview(reason)
    if not RC then return end
    if preview.world then RC.unbind(preview.world) end
    if preview.feed then RC.unbind(preview.feed) end
    if preview.camera then RC.destroy(preview.camera) end
    preview.camera, preview.feed, preview.world, preview.model = nil, nil, nil, nil
    preview.suppressed = false
    applied = { camera = {}, feed = {}, world = {} }
    pending = { camera = nil, feed = nil, world = nil }
    createAttempts, createRetryAt, bindRetryAt = 0, 0, 0
    states.source, states.feed, states.world = { state = "none" }, { state = "none" }, { state = "none" }
    if reason then log("preview stopped (" .. tostring(reason) .. ")") end
end

local function startPreview()
    if not RC or preview.camera then return preview.camera ~= nil end
    local camera, reason = RC.create(viewOf(draft.camera))
    if not camera then
        createAttempts = createAttempts + 1
        createRetryAt = now() + 3.0
        reportState("source", "failed", reason, { detail = string.format("retry %d", createAttempts) })
        return nil, reason
    end
    preview.camera = camera
    applied.camera = viewOf(draft.camera)
    createAttempts, createRetryAt = 0, 0
    reportState("source", "pending", nil)
    return true
end

local function bindFeed()
    if not preview.camera or preview.feed or not preview.rect then return end
    local binding, reason = RC.bindWebUI(preview.camera, page, preview.rect)
    if not binding then
        reportState("feed", "failed", reason)
        return nil, reason
    end
    preview.feed = binding
    applied.feed = { x = preview.rect.x, y = preview.rect.y, width = preview.rect.width, height = preview.rect.height }
    reportState("feed", "pending", nil)
    return true
end

local function bindWorld()
    if not preview.camera or preview.world or not draft then return end
    if preview.suppressed then
        -- The service panel is already drawn at the saved pose; a second panel
        -- in the same place would fight it. The preview comes back as soon as
        -- the draft diverges, or when the page asks for it.
        reportState("world", "hidden", nil)
        reportState("localPreview", "hidden", nil)
        return
    end
    local placement = worldPlacementOf(draft.placement, draft.model)
    local binding, reason = RC.bindWorld(preview.camera, placement)
    if not binding then
        reportState("world", "failed", reason)
        return nil, reason
    end
    preview.world = binding
    preview.model = draft.model
    applied.world = {
        position = { x = placement.position.x, y = placement.position.y, z = placement.position.z },
        rotation = { yaw = placement.rotation.yaw, pitch = placement.rotation.pitch, roll = placement.rotation.roll },
        width = placement.width, height = placement.height, model = placement.model,
        parent = placement.parent and (placement.parent.type .. ":" .. tostring(placement.parent.id)) or nil,
    }
    reportState("world", "pending", nil)
    return true
end

local function sameVector(a, b)
    if a == nil and b == nil then return true end
    if a == nil or b == nil then return false end
    return a.x == b.x and a.y == b.y and a.z == b.z
end

local function sameRotation(a, b)
    if a == nil and b == nil then return true end
    if a == nil or b == nil then return false end
    return a.yaw == b.yaw and a.pitch == b.pitch and a.roll == b.roll
end

local function queueCamera()
    if not draft or not preview.camera then return end
    local patch = {}
    if not sameVector(applied.camera.position, draft.camera.position) then patch.position = draft.camera.position end
    if not sameRotation(applied.camera.rotation, draft.camera.rotation) then patch.rotation = draft.camera.rotation end
    if applied.camera.fov ~= draft.camera.fov then patch.fov = draft.camera.fov end
    if applied.camera.range ~= draft.camera.range then patch.range = draft.camera.range end
    pending.camera = next(patch) and patch or nil
end

local function queueFeed()
    if not preview.feed or not preview.rect then return end
    local current, rect = applied.feed, preview.rect
    if current.x == rect.x and current.y == rect.y and current.width == rect.width and current.height == rect.height then return end
    pending.feed = { x = rect.x, y = rect.y, width = rect.width, height = rect.height }
end

local function queueWorld()
    if not preview.world or not draft then return end
    -- Compare what the native holds against what it should hold, both in the
    -- model's own frame: the patch carries the applied yaw, the draft keeps the
    -- authored one.
    local target = worldPlacementOf(draft.placement, draft.model)
    local patch, current = {}, applied.world
    if not sameVector(current.position, target.position) then patch.position = target.position end
    if not sameRotation(current.rotation, target.rotation) then patch.rotation = target.rotation end
    if current.width ~= target.width then patch.width = target.width end
    if current.height ~= target.height then patch.height = target.height end
    local parentKey = target.parent and (target.parent.type .. ":" .. tostring(target.parent.id)) or nil
    if current.parent ~= parentKey then
        -- The public Lua patch detaches with `parent = false`; `clearParent` is
        -- the internal native field and is not part of the script surface.
        if target.parent then patch.parent = target.parent else patch.parent = false end
    end
    pending.world = next(patch) and patch or nil
end

-- The local placement preview is a native world binding of this client's own
-- camera source. It is hidden while a saved service panel already occupies the
-- same pose, and shown again the moment the draft diverges or the page asks.
local function setPlacementPreview(enabled, reason)
    if not RC or not draft then return end
    preview.suppressed = not enabled
    preview.reason = reason
    if enabled then
        reportState("localPreview", "shown", reason)
        bindWorld()
        queueWorld()
    else
        if preview.world then RC.unbind(preview.world); preview.world = nil end
        pending.world = nil
        reportState("world", "hidden", reason)
        reportState("localPreview", "hidden", reason)
    end
    send("editor:states", states)
end

-- Whether the draft has moved away from the record the session started from.
-- That is what decides if a local placement preview is worth showing again.
local function draftDirty()
    if not draft or not baseDraft then return false end
    if draft.model ~= baseDraft.model or draft.cameraKey ~= baseDraft.cameraKey then return true end
    local camera, baseCamera = draft.camera, baseDraft.camera
    if camera.fov ~= baseCamera.fov or camera.range ~= baseCamera.range then return true end
    for _, axis in ipairs({ "x", "y", "z" }) do
        if camera.position[axis] ~= baseCamera.position[axis] then return true end
    end
    for _, axis in ipairs({ "yaw", "pitch", "roll" }) do
        if camera.rotation[axis] ~= baseCamera.rotation[axis] then return true end
    end
    local placement, basePlacement = draft.placement, baseDraft.placement
    if placement.width ~= basePlacement.width or placement.height ~= basePlacement.height
        or placement.radius ~= basePlacement.radius or placement.access ~= basePlacement.access then
        return true
    end
    for _, axis in ipairs({ "x", "y", "z" }) do
        if placement.position[axis] ~= basePlacement.position[axis] then return true end
    end
    for _, axis in ipairs({ "yaw", "pitch", "roll" }) do
        if placement.rotation[axis] ~= basePlacement.rotation[axis] then return true end
    end
    local parentA, parentB = placement.parent, basePlacement.parent
    if (parentA == nil) ~= (parentB == nil) then return true end
    if parentA and parentB then
        if parentA.type ~= parentB.type or tostring(parentA.id) ~= tostring(parentB.id) then return true end
    end
    return false
end

local function applyPending()
    if not session or not draft or not RC then return end
    if preview.camera == nil then
        if now() >= createRetryAt and createAttempts < 10 then startPreview() end
        if preview.camera == nil then return end
    end
    if (preview.feed == nil or preview.world == nil) and now() >= bindRetryAt then
        bindRetryAt = now() + 2.0
        bindFeed()
        bindWorld()
    end
    if pending.camera then
        local patch = pending.camera
        pending.camera = nil
        local ok, reason = RC.update(preview.camera, patch)
        if ok then
            for key, value in pairs(patch) do applied.camera[key] = value end
        else
            reportState("source", "failed", reason)
        end
    end
    if pending.feed then
        local patch = pending.feed
        pending.feed = nil
        local ok, reason = RC.updateBinding(preview.feed, patch)
        if ok then for key, value in pairs(patch) do applied.feed[key] = value end
        else reportState("feed", "failed", reason) end
    end
    if pending.world then
        local patch = pending.world
        pending.world = nil
        local ok, reason = RC.updateBinding(preview.world, patch)
        if ok then
            for key, value in pairs(patch) do
                if key ~= "parent" then applied.world[key] = value end
            end
            if patch.parent == false then
                applied.world.parent = nil
            elseif type(patch.parent) == "table" then
                applied.world.parent = patch.parent.type .. ":" .. tostring(patch.parent.id)
            end
        else
            reportState("world", "failed", reason)
        end
    end
end

-- `budget` is host policy, not something this resource may set: the chip only
-- reports a usage pair when the snapshot actually carries one.
local function budgetDetail(budget)
    if type(budget) ~= "table" then return nil end
    local global = budget.cameras
    local owned = type(budget.owner) == "table" and budget.owner.cameras or nil
    if type(global) ~= "table" or type(owned) ~= "table" then return nil end
    if not finite(global.used) or not finite(global.limit)
        or not finite(owned.used) or not finite(owned.limit) then return nil end
    return string.format("%d/%d global · %d/%d resource",
        global.used, global.limit, owned.used, owned.limit)
end

local function pollStates()
    if not session or not RC then return end
    if preview.camera then
        local snapshot, reason = RC.get(preview.camera)
        if type(snapshot) == "table" then
            local detail
            if finite(snapshot.width) and finite(snapshot.height) then detail = string.format("%dx%d", snapshot.width, snapshot.height) end
            reportState("source", snapshot.state or "unknown", snapshot.reason, { detail = detail })
        else
            reportState("source", "removed", reason)
        end
    end
    if preview.feed then
        local snapshot, reason = RC.getBinding(preview.feed)
        reportState("feed", type(snapshot) == "table" and (snapshot.state or "unknown") or "removed",
            type(snapshot) == "table" and snapshot.reason or reason)
    end
    if preview.world then
        local snapshot, reason = RC.getBinding(preview.world)
        reportState("world", type(snapshot) == "table" and (snapshot.state or "unknown") or "removed",
            type(snapshot) == "table" and snapshot.reason or reason)
    end
    local budget, reason = RC.budget()
    reportState("budget", budget and "active" or "unavailable", reason,
        { detail = budgetDetail(budget) })
end

-- ---------------------------------------------------------------------------
-- Aim, snap and parent handling
-- ---------------------------------------------------------------------------

local function applySnappedSurface()
    local ray, reason = Open77.camera.screenRaycast(0.5, 0.5, AIM_DISTANCE)
    if not ray then return nil, reason end
    if ray.hit ~= true then return nil, "no_surface_within_range" end
    local position, normal = ray.position, ray.normal
    if type(position) ~= "table" or type(normal) ~= "table" then return nil, "incomplete_hit" end
    -- The canonical frameless surface has its centre at the entity origin, its
    -- local +X along the image right, +Z up and its FRONT NORMAL along -Y. A
    -- placement rotation is an entity yaw, whose own +Y is (-sin, cos), so the
    -- pose that puts the front on the hit normal is the one whose +Y is -N --
    -- no legacy +90 or +180 is added anywhere.
    local yaw = math.deg(math.atan(normal.x, -normal.y))
    local pitch = math.deg(math.asin(clamp(-normal.z, -1, 1)))
    local depth = draft.depth or 0.02
    local world = { x = position.x + normal.x * depth, y = position.y + normal.y * depth, z = position.z + normal.z * depth }
    -- The authored pose the model's basis is measured from: the model offset is
    -- folded in at presentation, not here.
    local worldOrientation = { yaw = yaw, pitch = pitch, roll = 0 }
    local parent = parentFromHit(ray.target)
    local localPose, parentReason
    if parent then
        local selector, selectorReason = parentSelector(parent)
        if selector then
            localPose, parentReason = toParentLocal(selector, { position = world, rotation = worldOrientation })
        else
            parentReason = selectorReason
        end
        if not localPose then parent = nil end
    end
    draft.anchor = { position = { x = position.x, y = position.y, z = position.z },
                     normal = { x = normal.x, y = normal.y, z = normal.z } }
    draft.placement.parent = parent
    if parent and localPose then
        draft.placement.position = localPose.position
        draft.placement.rotation = localPose.rotation
    else
        draft.placement.position = world
        draft.placement.rotation = worldOrientation
    end
    return true, nil, parentReason
end

function refocus()
    if page == nil then return false, "no_page" end
    if not page:hasFocus() and Open77.input.isCaptured() then
        -- A slash command and the chat briefly retain keyboard ownership; wait
        -- one scheduler turn instead of fighting for it.
        Wait(100)
    end
    page:show()
    local focused, reason = page:setFocus(true, true)
    aiming = false
    if not focused then
        log("page refused focus: " .. tostring(reason))
        return false, reason
    end
    send("editor:focus")
    -- The page may have been hidden while a live mode drove the draft; its
    -- fields would otherwise still show the pose from before.
    if draft then send("editor:syncDraft", { draft = copyDraft(draft) }) end
    return true
end

function performSnap()
    if not session then return end
    local ok, reason, parentReason = applySnappedSurface()
    refocus()
    if ok then
        setPlacementPreview(true, "snap")
        send("editor:applyDraft", { draft = copyDraft(draft), lastParent = draft.lastParent, ok = true,
            message = "Snapped to the aim surface." .. (parentReason and (" Parent not used: " .. tostring(parentReason)) or "") })
        send("editor:snapResult", { ok = true, message = "Snapped to the surface under the aim." })
        log("snap ok" .. (parentReason and (" (parent not used: " .. tostring(parentReason) .. ")") or ""))
    else
        send("editor:snapResult", { ok = false, reason = reason })
        log("snap refused: " .. tostring(reason))
    end
end

-- ---------------------------------------------------------------------------
-- Export text
-- ---------------------------------------------------------------------------

local function number(value, decimals) return string.format("%." .. decimals .. "f", value) end
local function vector(values, decimals)
    return string.format("{ x = %s, y = %s, z = %s }", number(values.x, decimals), number(values.y, decimals), number(values.z, decimals))
end
local function rotationText(rotation)
    return string.format("{ yaw = %s, pitch = %s, roll = %s }", number(rotation.yaw, 1), number(rotation.pitch, 1), number(rotation.roll, 1))
end
local function exportKey()
    if draft.key then return draft.key end
    local slug = draft.name:lower():gsub("[^%w]+", "-"):gsub("^%-+", ""):gsub("%-+$", ""):sub(1, 40)
    if slug == "" then slug = "screen" end
    return "editor." .. slug
end

local function isCanonical(parent)
    return parent ~= nil and (parent.type == "player" or parent.type == "vehicle" or parent.type == "prop")
end

local function luaExport()
    local parent = draft.placement.parent
    local canonicalParent = isCanonical(parent)
    local world = select(1, worldPose(draft.placement, draft.model))
    local lines = {}
    lines[#lines + 1] = "-- " .. (draft.name ~= "" and draft.name or exportKey()) .. " -- generated by the open77_remote_camera placement editor."
    lines[#lines + 1] = "--"
    lines[#lines + 1] = "-- Paste this into the SERVER script of the resource that should own the panel:"
    lines[#lines + 1] = "-- the service allocates under the calling resource's generation, and a viewer needs"
    lines[#lines + 1] = "-- an explicit grant on a `granted` panel."
    lines[#lines + 1] = "--"
    lines[#lines + 1] = "-- Everything under `options` is a RUNTIME value and is a parameter on purpose: a"
    lines[#lines + 1] = "-- routing bucket changes, a viewer is a session, and a parent id is a runtime"
    lines[#lines + 1] = "-- identity that is never stable across a restart."
    lines[#lines + 1] = ""
    lines[#lines + 1] = ("local CAMERA_KEY = %q"):format(exportKey())
    lines[#lines + 1] = ("local CAMERA_POSE = { position = %s, rotation = %s, fov = %s, range = %s }")
        :format(vector(draft.camera.position, 3), rotationText(draft.camera.rotation),
            number(draft.camera.fov, 1), number(draft.camera.range, 0))
    if draft.housing then
        lines[#lines + 1] = ("local CAMERA_HOUSING = { model = %q, offset = %s, yaw = %s }")
            :format(draft.housing.model, vector(draft.housing.offset, 3), number(draft.housing.yaw, 1))
        lines[#lines + 1] = "-- CAMERA_HOUSING is a server-owned prop at the camera pose, seen by everyone in"
        lines[#lines + 1] = "-- range; the service creates, moves and removes it with the camera."
    else
        lines[#lines + 1] = "local CAMERA_HOUSING = nil"
    end
    if canonicalParent then
        lines[#lines + 1] = ("local PARENT_TYPE = %q"):format(parent.type)
        lines[#lines + 1] = ("local LOCAL_POSE = { position = %s, rotation = %s }")
            :format(vector(draft.placement.position, 3), rotationText({
                yaw = appliedYaw(draft.placement, draft.model),
                pitch = draft.placement.rotation.pitch,
                roll = draft.placement.rotation.roll,
            }))
    else
        lines[#lines + 1] = "local PARENT_TYPE = nil"
        lines[#lines + 1] = "local LOCAL_POSE = nil"
    end
    if world then
        lines[#lines + 1] = ("local WORLD_POSE = { position = %s, rotation = %s }")
            :format(vector(world.position, 3), rotationText(world.rotation))
    else
        lines[#lines + 1] = "local WORLD_POSE = nil"
    end
    lines[#lines + 1] = ("local PANEL = { width = %s, height = %s, model = %q, radius = %s, access = %q }")
        :format(number(draft.placement.width, 3), number(draft.placement.height, 3), draft.model,
            number(draft.placement.radius, 0), draft.placement.access)
    lines[#lines + 1] = ("-- model %q: its %s degree yaw offset is already applied to the poses above"):format(
        draft.model, number(modelYawOffset(draft.model), 1))
    lines[#lines + 1] = ""
    lines[#lines + 1] = "-- options.bucket   routing bucket the camera and its viewers live in (required)"
    lines[#lines + 1] = "-- options.viewerId player id allowed to view a `granted` panel (required for granted)"
    lines[#lines + 1] = "-- options.parentId a runtime player/vehicle/prop id you re-resolve yourself; omit it"
    lines[#lines + 1] = "--                  to place the panel at the captured world pose instead"
    lines[#lines + 1] = "local function placeScreen(options)"
    lines[#lines + 1] = "    options = options or {}"
    lines[#lines + 1] = "    local bucket = tonumber(options.bucket)"
    lines[#lines + 1] = "    if bucket == nil then return nil, \"bucket_required\" end"
    lines[#lines + 1] = "    if PANEL.access == \"granted\" and tonumber(options.viewerId) == nil then"
    lines[#lines + 1] = "        return nil, \"viewer_required_for_granted_access\""
    lines[#lines + 1] = "    end"
    lines[#lines + 1] = "    local placement = {"
    lines[#lines + 1] = "        width = PANEL.width, height = PANEL.height, model = PANEL.model,"
    lines[#lines + 1] = "        radius = PANEL.radius, access = PANEL.access,"
    lines[#lines + 1] = "    }"
    lines[#lines + 1] = "    if options.parentId ~= nil then"
    if canonicalParent then
        lines[#lines + 1] = "        -- A parent id is a runtime identity: the caller re-resolves it, and the pose"
        lines[#lines + 1] = "        -- below is the LOCAL offset the editor captured against that parent."
        lines[#lines + 1] = "        if WORLD_POSE == nil then return nil, \"no_world_pose_for_parent\" end"
        lines[#lines + 1] = "        placement.position = LOCAL_POSE.position"
        lines[#lines + 1] = "        placement.rotation = LOCAL_POSE.rotation"
        lines[#lines + 1] = "        placement.parent = { type = PARENT_TYPE, id = options.parentId }"
    else
        lines[#lines + 1] = "        -- The editor previewed a client-only identity (a vanilla prop, an unowned"
        lines[#lines + 1] = "        -- body): there is no parent to store, so ask for none."
        lines[#lines + 1] = "        return nil, \"no_captured_parent_to_bind\""
    end
    lines[#lines + 1] = "    else"
    lines[#lines + 1] = "        if WORLD_POSE == nil then return nil, \"no_world_pose_to_fall_back_to\" end"
    lines[#lines + 1] = "        placement.position = WORLD_POSE.position"
    lines[#lines + 1] = "        placement.rotation = WORLD_POSE.rotation"
    lines[#lines + 1] = "    end"
    lines[#lines + 1] = "    local camera, cameraError = exports.open77_remote_camera:create({"
    lines[#lines + 1] = "        key = CAMERA_KEY, bucket = bucket, enabled = true,"
    lines[#lines + 1] = "        position = CAMERA_POSE.position, rotation = CAMERA_POSE.rotation,"
    lines[#lines + 1] = "        fov = CAMERA_POSE.fov, range = CAMERA_POSE.range,"
    lines[#lines + 1] = "        housing = CAMERA_HOUSING,"
    lines[#lines + 1] = "    })"
    lines[#lines + 1] = "    if not camera then return nil, \"camera_refused: \" .. tostring(cameraError) end"
    lines[#lines + 1] = "    local screen, screenError = exports.open77_remote_camera:createScreen(camera.id, placement)"
    lines[#lines + 1] = "    if not screen then"
    lines[#lines + 1] = "        -- The camera exists for this placement alone: do not leak it on a refusal."
    lines[#lines + 1] = "        exports.open77_remote_camera:remove(camera.id)"
    lines[#lines + 1] = "        return nil, \"screen_refused: \" .. tostring(screenError)"
    lines[#lines + 1] = "    end"
    lines[#lines + 1] = "    if PANEL.access == \"granted\" then"
    lines[#lines + 1] = "        local granted, grantError = exports.open77_remote_camera:setAccess(camera.id, tonumber(options.viewerId), { view = true })"
    lines[#lines + 1] = "        if not granted then"
    lines[#lines + 1] = "            exports.open77_remote_camera:remove(camera.id) -- cascades the screen and any view"
    lines[#lines + 1] = "            return nil, \"access_refused: \" .. tostring(grantError)"
    lines[#lines + 1] = "        end"
    lines[#lines + 1] = "    end"
    lines[#lines + 1] = "    return { cameraId = camera.id, cameraKey = camera.key, screenId = screen }"
    lines[#lines + 1] = "end"
    lines[#lines + 1] = ""
    lines[#lines + 1] = "-- local placed, placeError = placeScreen({ bucket = 0, viewerId = playerId, parentId = vehicleId })"
    return table.concat(lines, "\n")
end

local function jsonExport()
    local parent = draft.placement.parent
    local canonicalParent = isCanonical(parent)
    local world = select(1, worldPose(draft.placement, draft.model))
    -- A service record without a live parent is a world pose; that is what this
    -- document reports as `position`/`rotation`, with the local pose kept beside
    -- the parent when there is one to bind.
    local worldPose = world or { position = draft.placement.position, rotation = draft.placement.rotation }
    local payload = {
        name = draft.name ~= "" and draft.name or nil,
        key = draft.key,
        runtimeParameters = {
            bucket = "required: the routing bucket the camera and its viewers live in",
            viewerId = draft.placement.access == "granted"
                and "required: player id granted view access on a granted panel" or nil,
            parentId = canonicalParent
                and ("optional: a runtime " .. parent.type .. " id, re-resolved by the caller; omit to use worldFallback")
                or nil,
        },
        camera = {
            key = draft.cameraKey,
            position = draft.camera.position,
            rotation = draft.camera.rotation,
            fov = draft.camera.fov,
            range = draft.camera.range,
            enabled = true,
        },
        placement = {
            position = worldPose.position,
            rotation = worldPose.rotation,
            width = draft.placement.width,
            height = draft.placement.height,
            model = draft.model,
            modelYawOffsetApplied = modelYawOffset(draft.model),
            radius = draft.placement.radius,
            access = draft.placement.access,
            worldFallback = world and { position = world.position, rotation = world.rotation } or nil,
        },
    }
    if canonicalParent then
        payload.placement.parent = {
            type = parent.type,
            id = parent.id,
            runtimeId = true,
            localPose = {
                position = draft.placement.position,
                rotation = {
                    yaw = appliedYaw(draft.placement, draft.model),
                    pitch = draft.placement.rotation.pitch,
                    roll = draft.placement.rotation.roll,
                },
            },
            note = "runtime identity: re-resolve it per session. After a restart the stored record " ..
                "comes back at worldFallback and the parent is chosen again in the editor.",
        }
    elseif parent then
        payload.placement.clientOnlyParent = {
            type = parent.type,
            id = parent.id,
            saved = false,
            note = "client-only identity: the local preview followed it, the service record cannot, " ..
                "so the panel is created at worldFallback",
        }
    end
    return Open77.json.encode(payload)
end

-- ---------------------------------------------------------------------------
-- Page protocol
-- ---------------------------------------------------------------------------

local function applyServerDefinition(row)
    if type(row) ~= "table" then return false end
    local candidate = sanitizeDraft(row.draft or row)
    if not candidate then return false end
    draft = candidate
    draft.key = row.key or candidate.key
    draft.lastParent = row.lastParent or (type(row.draft) == "table" and row.draft.lastParent) or nil
    -- The stored pose carries the model's yaw offset; the draft is authored.
    draft.placement.rotation.yaw = authoredYaw(draft.placement.rotation.yaw, draft.model)
    baseDraft = copyDraft(draft)
    applied.camera, applied.world = {}, {}
    pending.camera, pending.world = nil, nil
    if preview.world then RC.unbind(preview.world); preview.world = nil end
    if preview.camera then
        if preview.feed then RC.unbind(preview.feed) end
        RC.destroy(preview.camera)
        preview.camera, preview.feed, applied.camera = nil, nil, {}
    end
    startPreview()
    queueCamera()
    reportState("panel", row.viewerState or "pending", row.viewerReason)
    setPlacementPreview(row.viewerState ~= "active", "reopened")
    queueWorld()
    return true
end

local function onDraft(payload)
    if not session or type(payload) ~= "table" then return end
    local nextDraft, reason = sanitizeDraft(payload.draft)
    if not nextDraft then
        log("draft refused: " .. tostring(reason))
        return
    end
    local previousDepth = draft.depth
    local hadParent = draft.placement.parent ~= nil
    if draft.model ~= nextDraft.model and preview.world then
        RC.unbind(preview.world)
        preview.world, pending.world = nil, nil
    end
    draft.name = nextDraft.name
    draft.model = nextDraft.model
    draft.cameraKey = nextDraft.cameraKey
    draft.camera = nextDraft.camera
    draft.placement.position = nextDraft.placement.position
    draft.placement.rotation = nextDraft.placement.rotation
    draft.placement.width = nextDraft.placement.width
    draft.placement.height = nextDraft.placement.height
    draft.placement.radius = nextDraft.placement.radius
    draft.placement.access = nextDraft.placement.access
    draft.placement.parent = nextDraft.placement.parent
    draft.depth = nextDraft.depth
    draft.anchor = nextDraft.anchor
    -- Depth is measured along the retained surface normal, so changing it moves
    -- the display off that surface without tracing again.
    if draft.anchor and previousDepth ~= draft.depth then
        local world = {
            x = draft.anchor.position.x + draft.anchor.normal.x * draft.depth,
            y = draft.anchor.position.y + draft.anchor.normal.y * draft.depth,
            z = draft.anchor.position.z + draft.anchor.normal.z * draft.depth,
        }
        if draft.placement.parent then
            local selector, selectorReason = parentSelector(draft.placement.parent)
            local pose = selector and toParentLocal(selector, { position = world, rotation = draft.placement.rotation })
            if pose then
                draft.placement.position = pose.position
            else
                draft.placement.position = world
                if not selector then log("parent frame unresolved: " .. tostring(selectorReason)) end
                draft.placement.parent = nil
            end
        else
            draft.placement.position = world
        end
        send("editor:applyDraft", { draft = copyDraft(draft), lastParent = draft.lastParent, ok = true,
            message = string.format("Depth %.3f m applied along the surface normal.", draft.depth) })
    end
    if hadParent and draft.placement.parent == nil then
        -- An id the platform rules refuse is dropped loudly, never silently
        -- re-pointed: a prop id must be a canonical decimal string and a
        -- player/vehicle id must be a number.
        send("editor:notice", { ok = false,
            message = "That parent reference was refused (a prop id must be a canonical decimal string, " ..
                "a player or vehicle id a number). The draft is now unparented." })
    end
    if preview.suppressed and draftDirty() then
        -- The draft has left the saved record behind: the local placement
        -- preview is worth showing again.
        setPlacementPreview(true, "draft_changed")
    end
    if not preview.suppressed then bindWorld() end
    queueCamera()
    queueWorld()
end

local function onAction(payload)
    if not session or type(payload) ~= "table" then return end
    local action = payload.action
    if action == "save" then
        local spec, reason = sanitizeDraft(payload.spec)
        if not spec then return send("editor:notice", { ok = false, message = "Draft refused: " .. tostring(reason) }) end
        local parent = draft.placement.parent
        local world, previewParent, worldReason
        if parent then
            world, worldReason = worldPose(draft.placement, draft.model)
            if not world then
                -- A parent that cannot be resolved right now cannot be saved:
                -- the stored world fallback would be a guess.
                return send("editor:notice", { ok = false,
                    message = "Save refused: the parent frame is unavailable (" .. tostring(worldReason) ..
                        "). Snap again, or clear the parent to save a world pose." })
            end
            if parent.type ~= "player" and parent.type ~= "vehicle" and parent.type ~= "prop" then
                -- A client-only identity (a vanilla prop, an unowned body): the
                -- preview follows it, the service record cannot.
                previewParent = { type = parent.type, id = parent.id }
            end
        end
        local placement = spec.placement
        if parent and not previewParent then
            -- The service record is the pose the native uses, so the model's
            -- yaw offset travels with it; the draft stays authored.
            placement = {
                position = { x = spec.placement.position.x, y = spec.placement.position.y, z = spec.placement.position.z },
                rotation = { yaw = appliedYaw(spec.placement, spec.model), pitch = spec.placement.rotation.pitch, roll = spec.placement.rotation.roll },
                width = spec.placement.width, height = spec.placement.height,
                radius = spec.placement.radius, access = spec.placement.access,
                parent = { type = parent.type, id = parent.id },
            }
        elseif previewParent then
            placement = {
                position = { x = world.position.x, y = world.position.y, z = world.position.z },
                rotation = { yaw = world.rotation.yaw, pitch = world.rotation.pitch, roll = world.rotation.roll },
                width = spec.placement.width, height = spec.placement.height,
                radius = spec.placement.radius, access = spec.placement.access,
            }
        elseif spec.placement.parent == nil then
            placement = {
                position = { x = spec.placement.position.x, y = spec.placement.position.y, z = spec.placement.position.z },
                rotation = { yaw = appliedYaw(spec.placement, spec.model), pitch = spec.placement.rotation.pitch, roll = spec.placement.rotation.roll },
                width = spec.placement.width, height = spec.placement.height,
                radius = spec.placement.radius, access = spec.placement.access,
            }
        end
        server("save", {
            key = draft.key, name = spec.name, model = spec.model, cameraKey = spec.cameraKey,
            camera = {
                position = spec.camera.position, rotation = spec.camera.rotation,
                fov = spec.camera.fov, range = spec.camera.range,
                -- The housing travels with the camera spec: the service owns the
                -- prop, and a spec without one takes an existing housing away.
                housing = spec.housing,
            },
            placement = placement, world = world, previewParent = previewParent,
        })
    elseif action == "delete" then
        if type(payload.key) == "string" then server("delete", { key = payload.key }) end
    elseif action == "reopen" then
        if type(payload.key) == "string" then server("reopen", { key = payload.key }) end
    elseif action == "reset" then
        if not baseDraft then return end
        draft = copyDraft(baseDraft)
        applied.camera, applied.world = {}, {}
        pending.camera, pending.world = nil, nil
        if preview.world then RC.unbind(preview.world); preview.world = nil end
        bindWorld()
        queueCamera()
        queueWorld()
        send("editor:applyDraft", { draft = copyDraft(draft), lastParent = draft.lastParent, ok = true, message = "Draft reset to how this session started." })
    elseif action == "close" then
        stopSession("cancelled", true)
    end
end

local function onSnapRequest()
    aiming = true
    if page then
        page:setFocus(false, false)
        page:hide()
    end
    send("editor:notice", { ok = true,
        message = string.format("Aim at the surface, then press %s (or run /remote-camera.editor snap). /remote-camera.editor brings the cursor back.", snapKey) })
end

local function onRelease()
    aiming = true
    if page then
        page:setFocus(false, false)
        page:hide()
    end
    send("editor:notice", { ok = true,
        message = string.format("Cursor released. Press %s to snap, or /remote-camera.editor to capture the cursor again.", snapKey) })
end

local function onCameraFromView()
    local view, reason = playerView()
    if not view then return send("editor:notice", { ok = false, message = "Player camera unavailable: " .. tostring(reason) }) end
    draft.camera = view
    queueCamera()
    send("editor:applyDraft", { draft = copyDraft(draft), lastParent = draft.lastParent, ok = true, message = "Camera pose replaced with the current player view." })
end

local function onUnparent()
    if not draft.placement.parent then return end
    local selector, selectorReason = parentSelector(draft.placement.parent)
    if not selector then
        return send("editor:notice", { ok = false,
            message = "Could not resolve the parent frame (" .. tostring(selectorReason) .. "); the pose was left alone." })
    end
    local pose, reason = fromParentLocal(selector, { position = draft.placement.position, rotation = draft.placement.rotation })
    if not pose then
        return send("editor:notice", { ok = false, message = "Could not resolve the parent frame: " .. tostring(reason) })
    end
    draft.placement.parent = nil
    draft.placement.position = pose.position
    draft.placement.rotation = pose.rotation
    queueWorld()
    send("editor:applyDraft", { draft = copyDraft(draft), lastParent = draft.lastParent, ok = true,
        message = "Parent cleared; the pose is world space now and the display stays where it was." })
end

local function onCopy(payload)
    local kind = type(payload) == "table" and payload.kind or "lua"
    local text = kind == "json" and jsonExport() or luaExport()
    if type(text) ~= "string" or #text == 0 then
        return send("editor:copyResult", { ok = false, kind = kind, reason = "encode_failed" })
    end
    local ok, reason = Open77.clipboard.setText(text)
    send("editor:copyResult", { ok = ok == true, kind = kind, reason = reason, length = #text })
end

-- ---------------------------------------------------------------------------
-- Live placement
-- ---------------------------------------------------------------------------

-- One live tick. `follow` takes position and yaw/pitch from the player's own
-- view and leaves the authored roll, FOV and range alone: the operator is
-- choosing where the camera stands, not what lens it has. `snap` re-runs the
-- same centre-screen pick F4 uses, so the surface rides the aim.
local function stepLive()
    if not session or not draft or not RC then return end
    local moved = false
    if live.follow then
        local view = playerView()
        if view then
            draft.camera.position = view.position
            draft.camera.rotation.yaw = view.rotation.yaw
            draft.camera.rotation.pitch = view.rotation.pitch
            moved = true
        end
    end
    if live.snap then
        local ok = applySnappedSurface()
        if ok then
            if preview.suppressed and draftDirty() then setPlacementPreview(true, "live_snap") end
            if not preview.suppressed then bindWorld() end
            moved = true
        end
    end
    if not moved then return end
    queueCamera()
    queueWorld()
    applyPending()
    if pageReady then
        local parent = draft.placement.parent
        send("editor:livePose", {
            camera = { position = draft.camera.position, rotation = draft.camera.rotation },
            placement = { position = draft.placement.position, rotation = draft.placement.rotation },
            -- The page cannot infer these: `snap` parents the surface when the
            -- ray lands on a body or a vehicle, and an absent anchor means the
            -- pose is manual from here on.
            snapped = draft.anchor ~= nil,
            anchor = draft.anchor and {
                position = { x = draft.anchor.position.x, y = draft.anchor.position.y, z = draft.anchor.position.z },
                normal = { x = draft.anchor.normal.x, y = draft.anchor.normal.y, z = draft.anchor.normal.z },
            } or nil,
            hasParent = parent ~= nil,
            parent = parent and { type = parent.type, id = parent.id } or nil,
        })
    end
end

local function liveSummary()
    if live.follow then
        return string.format("Positioning the CAMERA: walk, fly and look. Press %s to freeze.", followKey)
    end
    if live.snap then
        return string.format("Positioning the SURFACE: aim at the face you want. Press %s to freeze.", liveSnapKey)
    end
    return "Placement mode off: the fields and the step buttons own the pose again."
end

local function publishLive()
    send("editor:live", { follow = live.follow, snap = live.snap })
end

-- Modes are mutually exclusive: "follow" positions the camera, "snap" the
-- surface, and "off" returns control to the fields.
local function applyLiveMode(mode)
    if not session then return end
    local wasLive = live.follow or live.snap
    live.follow = mode == "follow"
    live.snap = mode == "snap"
    if live.follow or live.snap then
        -- The whole point of a live mode is that the game owns the input, so
        -- the cursor goes back to it the moment one is armed.
        aiming = true
        if page then
            page:setFocus(false, false)
            page:hide()
        end
    elseif wasLive then
        refocus()
    end
    publishLive()
    -- The page hides while a mode is armed, so the mode is announced where it
    -- can still be read from inside the game.
    chatNotice(liveSummary())
    send("editor:notice", { ok = true, message = liveSummary() })
    log(("live mode=%s"):format(mode))
end

-- A key can arrive through both the page and the engine mapping. Debounce
-- their shared toggle so one press cannot immediately undo itself.
local lastToggle = { kind = nil, at = -1000 }
local function toggleLive(kind)
    if not session or (kind ~= "follow" and kind ~= "snap") then return end
    local at = now()
    if lastToggle.kind == kind and at - lastToggle.at < 0.15 then return end
    lastToggle.kind, lastToggle.at = kind, at
    applyLiveMode(live[kind] and "off" or kind)
end

-- ---------------------------------------------------------------------------
-- Camera prop
-- ---------------------------------------------------------------------------

local function cameraPropPose()
    if not draft then return nil end
    local camera = draft.camera
    return {
        x = camera.position.x, y = camera.position.y, z = camera.position.z,
        yaw = camera.rotation.yaw,
    }
end

local function samePropPose(a, b)
    if a == nil or b == nil then return false end
    return a.x == b.x and a.y == b.y and a.z == b.z and a.yaw == b.yaw
end

local function removeCameraProp()
    if cameraProp.id == nil then return end
    Open77.props.remove(cameraProp.id)
    cameraProp.id, cameraProp.pose = nil, nil
end

local function reportCameraProp(message, ok)
    send("editor:cameraPropState", { model = cameraProp.model, message = message, ok = ok })
    if message then chatNotice(message) end
end

-- Keeps the local housing on the source pose. Called from the tick loop rather
-- than from every edit, so a live mode and a typed coordinate move it the same
-- way -- and a pose that has not changed costs one table compare.
local function syncCameraProp()
    if not session or not draft then return end
    if cameraProp.model == nil then
        removeCameraProp()
        return
    end
    -- Once the record carries the housing the service owns the prop, and a second
    -- one at the same pose would z-fight with it. The local copy comes back the
    -- moment the draft diverges again, exactly like the panel preview.
    if cameraProp.saved and not draftDirty() then
        removeCameraProp()
        return
    end
    local pose = cameraPropPose()
    if not pose then return end
    if cameraProp.id == nil then
        local id, reason = Open77.props.create({
            model = cameraProp.model,
            position = { x = pose.x, y = pose.y, z = pose.z },
            yaw = pose.yaw,
        })
        if not id then
            -- A refused model is not retried every tick: the operator is told
            -- once and the toggle is cleared, so the state matches reality.
            log("camera prop refused: " .. tostring(reason))
            cameraProp.model = nil
            reportCameraProp("Camera prop refused (" .. tostring(reason) .. ").", false)
            return
        end
        cameraProp.id, cameraProp.pose = id, pose
        log("camera prop " .. cameraProp.model .. " id=" .. tostring(id))
        return
    end
    if samePropPose(cameraProp.pose, pose) then return end
    local ok, reason = Open77.props.setTransform(cameraProp.id,
        { position = { x = pose.x, y = pose.y, z = pose.z }, yaw = pose.yaw })
    if ok then cameraProp.pose = pose else log("camera prop move refused: " .. tostring(reason)) end
end

local function onCameraProp(payload)
    if not session or not draft then return end
    local wanted = type(payload) == "table" and payload.model or nil
    if type(wanted) ~= "string" or wanted == "" then wanted = nil end
    -- The draft owns the housing: it is saved with the placement, and the local
    -- prop below is only this client's preview of it.
    draft.housing = wanted and {
        model = wanted,
        offset = draft.housing and draft.housing.offset
            or { x = CAMERA_PROP_OFFSET.x, y = CAMERA_PROP_OFFSET.y, z = CAMERA_PROP_OFFSET.z },
        yaw = draft.housing and draft.housing.yaw or 0.0,
    } or nil
    cameraProp.model = wanted
    cameraProp.saved = false
    removeCameraProp()
    syncCameraProp()
    send("editor:syncDraft", { draft = copyDraft(draft) })
    reportCameraProp(wanted and ("Camera prop " .. wanted .. " follows the source pose; SAVE puts it on the wall for everyone.")
        or "Camera prop removed; SAVE takes it off the wall.", true)
end

local function onRect(payload)
    if type(payload) ~= "table" then return end
    if not (finite(payload.x) and finite(payload.y) and finite(payload.width) and finite(payload.height)) then return end
    preview.rect = {
        x = math.floor(clamp(payload.x, -8192, 8192)),
        y = math.floor(clamp(payload.y, -8192, 8192)),
        width = math.floor(clamp(payload.width, 16, 8192)),
        height = math.floor(clamp(payload.height, 16, 8192)),
    }
    bindFeed()
    queueFeed()
end

-- ---------------------------------------------------------------------------
-- Session lifecycle
-- ---------------------------------------------------------------------------

function stopSession(reason, notifyServer)
    if not session then return end
    local token = session.token
    session = nil
    aiming = false
    live.follow, live.snap = false, false
    removeCameraProp()
    cameraProp.model = nil
    stopPreview(reason)
    if notifyServer and token then
        TriggerServerEvent("open77:remoteCamera:editor:action", { action = "close", token = token })
    end
    if page then
        page:setFocus(false, false)
        page:hide()
    end
    if draft then send("editor:closed", { reason = reason }) end
    draft, baseDraft = nil, nil
end

function finishOpen()
    local payload = pendingOpen
    pendingOpen = nil
    if type(payload) ~= "table" then return end
    session = { token = payload.session.token, bucket = payload.session.bucket, editingKey = payload.session.editingKey }
    states.bucket = { state = "active", detail = tostring(session.bucket) }
    local candidate
    if type(payload.draft) == "table" then
        candidate = sanitizeDraft(payload.draft)
        if candidate then
            -- A draft from the server is the stored pose the native uses, so it
            -- carries the model's yaw offset; the draft the user edits is the
            -- authored one.
            candidate.placement.rotation.yaw = authoredYaw(candidate.placement.rotation.yaw, candidate.model)
        end
    end
    if not candidate then
        local fresh, reason = newDraft()
        if not fresh then
            session = nil
            TriggerServerEvent("open77:remoteCamera:editor:action", { action = "close", token = payload.session.token })
            chatNotice("The Remote Camera editor could not read your view: " .. tostring(reason))
            return
        end
        candidate = fresh
    end
    draft = candidate
    draft.key = payload.session.editingKey or candidate.key
    -- A reopened placement may already have a housing; the service owns that one,
    -- so the local preview starts stood down.
    cameraProp.model = draft.housing and draft.housing.model or nil
    cameraProp.saved = draft.housing ~= nil
    cameraProp.pose = nil
    if type(payload.draft) == "table" then draft.lastParent = payload.draft.lastParent end
    baseDraft = copyDraft(draft)
    -- A saved definition is not necessarily drawn for this viewer. Suppress
    -- the local copy only once the service presentation is actually active.
    preview.suppressed, preview.reason = false, "reopened"
    reportState("panel", "none", nil)
    for _, row in ipairs(payload.definitions or {}) do
        if row.key == draft.key then
            preview.suppressed = row.viewerState == "active"
            reportState("panel", row.viewerState or "pending", row.viewerReason)
            break
        end
    end
    if RC.worldModels then
        local list = RC.worldModels()
        if type(list) == "table" and #list > 0 then models = list end
    end
    page:show()
    local focused, focusReason = page:setFocus(true, true)
    if not focused then
        session = nil
        stopPreview("focus_refused")
        TriggerServerEvent("open77:remoteCamera:editor:action", { action = "close", token = payload.session.token })
        chatNotice("The Remote Camera editor page refused focus: " .. tostring(focusReason))
        return
    end
    startPreview()
    queueCamera()
    bindWorld()
    queueWorld()
    send("editor:open", {
        session = session,
        draft = copyDraft(draft),
        lastParent = draft.lastParent,
        definitions = payload.definitions or {},
        cameras = payload.cameras or {},
        models = models,
        bucket = session.bucket,
        editingKey = session.editingKey,
        limits = payload.limits or { maxDefinitions = 24 },
        focusKey = snapKey,
        followKey = followKey,
        liveSnapKey = liveSnapKey,
        live = { follow = live.follow, snap = live.snap },
        cameraProp = { model = cameraProp.model, default = CAMERA_PROP_DEFAULT },
    })
    send("editor:states", states)
    log(("editor open token=%s editing=%s bucket=%s"):format(tostring(session.token), tostring(session.editingKey), tostring(session.bucket)))
end

function openEditor(payload)
    if type(payload) ~= "table" or type(payload.session) ~= "table" then return end
    local token = payload.session.token
    local function refuse(message)
        TriggerServerEvent("open77:remoteCamera:editor:action", { action = "close", token = token })
        chatNotice(message)
    end
    if not RC then return refuse("This client has no remoteCamera API; the placement editor is unavailable.") end
    if not page then return refuse("The Remote Camera editor page is unavailable" .. (pageReason and (": " .. tostring(pageReason)) or ".")) end
    if session and session.token == token then
        -- The same session: the command is a refocus and a list refresh. The
        -- draft in progress is not touched.
        session.bucket = payload.session.bucket or session.bucket
        if type(payload.definitions) == "table" then send("editor:definitions", { rows = payload.definitions }) end
        if type(payload.cameras) == "table" then send("editor:cameras", { rows = payload.cameras }) end
        refocus()
        return
    end
    -- A slash command briefly retains the chat's focus until its handler
    -- completes; wait one scheduler turn rather than stealing another modal.
    if Open77.input.isCaptured() then
        Wait(100)
        if Open77.input.isCaptured() then
            return refuse("Another menu owns input right now; close it and run /remote-camera.editor again.")
        end
    end
    pendingOpen = payload
    if not pageReady then
        openDeadline = now() + 10.0
        return
    end
    openDeadline = 0
    finishOpen()
end

-- ---------------------------------------------------------------------------
-- Server events
-- ---------------------------------------------------------------------------

RegisterNetEvent("open77:remoteCamera:editor:open", function(payload) openEditor(payload) end)
RegisterNetEvent("open77:remoteCamera:editor:draft", function(payload)
    if not session or type(payload) ~= "table" then return end
    if not applyServerDefinition(payload) then return end
    if type(draft.key) == "string" then session.editingKey = draft.key end
    send("editor:applyDraft", { draft = copyDraft(draft), lastParent = draft.lastParent, ok = true, message = payload.message or "Definition loaded." })
end)
RegisterNetEvent("open77:remoteCamera:editor:definitions", function(payload)
    if not session then return end
    send("editor:definitions", { rows = type(payload) == "table" and payload.rows or {} })
end)
RegisterNetEvent("open77:remoteCamera:editor:cameras", function(payload)
    if not session then return end
    send("editor:cameras", { rows = type(payload) == "table" and payload.rows or {} })
end)
RegisterNetEvent("open77:remoteCamera:editor:presentation", function(payload)
    if not session or type(payload) ~= "table" then return end
    local mine = (draft and (payload.key == draft.key or payload.key == session.editingKey)) == true
    if mine then
        reportState("panel", payload.state or "unknown", payload.reason,
            { detail = payload.screenId and ("#" .. tostring(payload.screenId)) or nil })
        if preview.reason ~= "page" and not draftDirty() then
            setPlacementPreview(payload.state ~= "active", "presentation")
        end
    end
    send("editor:presentation", payload)
end)
RegisterNetEvent("open77:remoteCamera:editor:saved", function(payload)
    if type(payload) ~= "table" then return end
    if not session then return end
    if payload.ok == true and type(payload.definition) == "table" then
        -- The stored record is the truth: if the server kept a world pose
        -- because a parent could not be persisted, the draft follows it.
        local row, placed = payload.definition, payload.definition.placement
        draft.key = row.key
        draft.cameraKey = row.cameraKey
        draft.camera = viewOf(row.camera)
        queueCamera()
        draft.lastParent = row.lastParent
        session.editingKey = row.key
        if type(placed) == "table" then
            if placed.parent ~= nil or draft.placement.parent ~= nil then
                draft.placement.parent = placed.parent
                draft.placement.position = { x = placed.position.x, y = placed.position.y, z = placed.position.z }
                -- The stored record is the model's own pose; the draft keeps the
                -- authored yaw, so subtracting once here is what stops a model
                -- switch from accumulating offsets.
                draft.placement.rotation = {
                    yaw = authoredYaw(placed.rotation.yaw, draft.model),
                    pitch = placed.rotation.pitch,
                    roll = placed.rotation.roll,
                }
                applied.world, pending.world = {}, nil
                if preview.world then RC.unbind(preview.world); preview.world = nil end
                bindWorld()
                queueWorld()
            end
            if placed.width then
                draft.placement.width, draft.placement.height = placed.width, placed.height
            end
            if placed.radius then draft.placement.radius, draft.placement.access = placed.radius, placed.access end
        end
        baseDraft = copyDraft(draft)
        -- The service owns the housing from here: the local preview steps aside
        -- until the draft diverges again.
        if draft.housing then
            cameraProp.model = draft.housing.model
            cameraProp.saved = true
            removeCameraProp()
        else
            cameraProp.model, cameraProp.saved = nil, false
            removeCameraProp()
        end
        reportState("panel", payload.viewerState or "pending", payload.viewerReason,
            { detail = payload.screenId and ("#" .. tostring(payload.screenId)) or nil })
        -- Keep the local copy until this viewer's service presentation is active.
        setPlacementPreview(payload.viewerState ~= "active", "saved")
    end
    send("editor:saved", payload)
end)
RegisterNetEvent("open77:remoteCamera:editor:deleted", function(payload)
    if not session or type(payload) ~= "table" then return end
    if payload.ok == true and payload.key == session.editingKey then
        session.editingKey = nil
        draft.key = nil
        baseDraft.key = nil
        reportState("panel", "none", "deleted")
    end
    send("editor:deleted", payload)
end)
RegisterNetEvent("open77:remoteCamera:editor:notice", function(payload)
    if type(payload) ~= "table" then return end
    send("editor:notice", payload)
    log(tostring(payload.message))
end)
RegisterNetEvent("open77:remoteCamera:editor:closed", function(payload)
    local reason = type(payload) == "table" and payload.reason or "server_closed"
    local had = session ~= nil
    session = nil
    aiming = false
    live.follow, live.snap = false, false
    removeCameraProp()
    cameraProp.model = nil
    stopPreview(reason)
    if page then
        page:setFocus(false, false)
        page:hide()
    end
    if had or draft then send("editor:closed", { reason = reason }) end
    draft, baseDraft, pendingOpen = nil, nil, nil
    log("editor closed by the server: " .. tostring(reason))
end)
RegisterNetEvent("open77:remoteCamera:editor:snap", function()
    if session then performSnap() end
end)

-- Native state changes arrive as resource-local events; the poll is the
-- fallback, these make a transition visible on the frame it happens.
AddEventHandler("open77:remoteCamera:stateChanged", function(event)
    if not session or type(event) ~= "table" or event.cameraId ~= preview.camera then return end
    reportState("source", event.state or "unknown", event.reason)
end)
AddEventHandler("open77:remoteCamera:bindingChanged", function(event)
    if not session or type(event) ~= "table" then return end
    if event.bindingId == preview.feed then reportState("feed", event.state or "unknown", event.reason) end
    if event.bindingId == preview.world then reportState("world", event.state or "unknown", event.reason) end
end)

-- ---------------------------------------------------------------------------
-- Startup
-- ---------------------------------------------------------------------------

AddEventHandler("onClientResourceStart", function(name)
    if name ~= RESOURCE then return end
    if not RC then
        log("remoteCamera missing on this client: the placement editor stays closed")
        return
    end
    page, pageReason = WebUI.create({
        entry = PAGE_ENTRY, layer = "menu", zIndex = 760, width = 1920, height = 1080,
        fps = 30, transparent = true, visible = false,
    })
    if not page then
        log("editor page unavailable: " .. tostring(pageReason))
        return
    end
    page:on("editor:ready", function()
        if not pageReady then log("page handshake complete") end
        pageReady = true
        if pendingOpen then finishOpen() end
    end)
    page:on("editor:draft", onDraft)
    page:on("editor:rect", onRect)
    page:on("editor:snap", onSnapRequest)
    page:on("editor:releaseCursor", onRelease)
    page:on("editor:cameraFromView", onCameraFromView)
    page:on("editor:unparent", onUnparent)
    page:on("editor:copy", onCopy)
    page:on("editor:togglePreview", function() setPlacementPreview(preview.suppressed, "page") end)
    page:on("editor:toggleFollow", function() toggleLive("follow") end)
    page:on("editor:toggleSnap", function() toggleLive("snap") end)
    page:on("editor:liveOff", function() applyLiveMode("off") end)
    page:on("editor:cameraProp", onCameraProp)
    page:on("editor:action", onAction)

    local registered, key = RegisterKeyMapping(SNAP_KEY, "Remote Camera Editor: snap to aim", SNAP_KEY_DEFAULT, function()
        if session then performSnap() end
    end)
    if registered and type(key) == "string" then snapKey = key end

    local followRegistered, followBinding = RegisterKeyMapping(FOLLOW_KEY,
        "Remote Camera Editor: the camera follows the player view", FOLLOW_KEY_DEFAULT, function()
            if session then toggleLive("follow") end
        end)
    if followRegistered and type(followBinding) == "string" then followKey = followBinding end

    local liveSnapRegistered, liveSnapBinding = RegisterKeyMapping(LIVESNAP_KEY,
        "Remote Camera Editor: the surface follows the aim", LIVESNAP_KEY_DEFAULT, function()
            if session then toggleLive("snap") end
        end)
    if liveSnapRegistered and type(liveSnapBinding) == "string" then liveSnapKey = liveSnapBinding end

    -- Positioning runs at ~30 Hz independently of the 100 ms status loop below.
    CreateThread(function()
        while page do
            if session and (live.follow or live.snap) then
                stepLive()
                Wait(math.floor(LIVE_INTERVAL * 1000))
            else
                Wait(120)
            end
        end
    end)

    CreateThread(function()
        while page do
            if pendingOpen and not pageReady and openDeadline > 0 and now() > openDeadline then
                local token = pendingOpen.session and pendingOpen.session.token
                pendingOpen, openDeadline = nil, 0
                if token then TriggerServerEvent("open77:remoteCamera:editor:action", { action = "close", token = token }) end
                log("the editor page did not answer; open refused")
                chatNotice("The Remote Camera editor page did not load; see the client log.")
            end
            if session then
                applyPending()
                syncCameraProp()
                queueCamera()
                queueFeed()
                queueWorld()
                pollStates()
            end
            Wait(100)
        end
    end)
end)

AddEventHandler("onClientResourceStop", function(name)
    if name ~= RESOURCE then return end
    stopPreview("resource_stop")
    page, pageReady, session, draft, baseDraft, pendingOpen = nil, false, nil, nil, nil, nil
end)

AddEventHandler("open77:pauseKey", function()
    if session then stopSession("pause", true) end
end)
AddEventHandler("open77:worldReady", function()
    if session then stopSession("world_transition", true) end
end)

exports("editorState", function()
    return {
        page = page ~= nil,
        ready = pageReady,
        open = session ~= nil,
        editingKey = session and session.editingKey or nil,
        token = session and session.token or nil,
        aiming = aiming,
        snapKey = snapKey,
        followKey = followKey,
        liveSnapKey = liveSnapKey,
        live = { follow = live.follow, snap = live.snap },
        cameraProp = { id = cameraProp.id, model = cameraProp.model },
        preview = { camera = preview.camera, feed = preview.feed, world = preview.world,
                    rect = preview.rect, model = preview.model },
        states = states,
        draft = draft and copyDraft(draft) or nil,
    }
end)
