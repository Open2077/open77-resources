-- ACL-gated placement editor. Net mutations recheck the command permission.
-- RemoteCameraService owns live records; KVP definitions reconstruct missing owned
-- sources and screens. Persisted runtime parents require explicit reselection.

local OWNER = GetCurrentResourceName()
local GENERATION = GetCurrentResourceGeneration()
local STORE_KEY = "remote-camera.editor.definitions.v1"
local STORE_VERSION = 1
local STORE_MAX_BYTES = 60000
local MAX_DEFINITIONS = 24
local MAX_CAMERA_ROWS = 24
local DEFAULT_RADIUS = 40
local DEFAULT_DEPTH = 0.02
local CAMERA_PREFIX = "editor."
local RECONCILE_INTERVAL = 5.0
local PRESENTATION_INTERVAL = 0.7
local MESSAGE_CAPACITY = 30
local MESSAGE_REFILL = 10.0
local KEY_PATTERN = "^[%w%._%-]+$"
local PARENT_TYPES_CANONICAL = { prop = true, player = true, vehicle = true }

local definitions, byKey = {}, {}
local sessions = {}
local sequence = 0

local function log(text) print("[remote-camera-editor] " .. tostring(text)) end
local function now() return Open77.time.monotonic() end
local function finite(value) return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge end
local function clamp(value, low, high) return math.min(high, math.max(low, value)) end
local function wrapDegrees(value) return (value + 180) % 360 - 180 end
local function service() return RemoteCameraService end

local function output(source, raw, success, text)
    print(text)
    if source ~= nil and source > 0 then
        TriggerClientEvent("open77:command:result", source, raw or "", success == true, text)
    end
end

local function notice(player, ok, message, kind)
    TriggerClientEvent("open77:remoteCamera:editor:notice", player, { ok = ok == true, message = message, kind = kind })
end

-- ---------------------------------------------------------------------------
-- Validation
-- ---------------------------------------------------------------------------

local function validVector(value, magnitude)
    if type(value) ~= "table" then return false end
    for _, axis in ipairs({ "x", "y", "z" }) do
        if not finite(value[axis]) or math.abs(value[axis]) > magnitude then return false end
    end
    return true
end

local function validRotation(value)
    if type(value) ~= "table" then return false end
    for _, axis in ipairs({ "yaw", "pitch", "roll" }) do
        local component = value[axis]
        if component ~= nil and (not finite(component) or math.abs(component) > 100000) then return false end
    end
    return value.yaw ~= nil
end

local function cleanRotation(value)
    return { yaw = wrapDegrees(value.yaw or 0), pitch = finite(value.pitch) and wrapDegrees(value.pitch) or 0,
             roll = finite(value.roll) and wrapDegrees(value.roll) or 0 }
end

-- Parent ids are platform identities and are never converted between kinds:
--   prop            canonical decimal u64 string ("0", "007" and 21+ digits are invalid)
--   player/vehicle  numeric platform ids; a quoted id is refused, not coerced
local U64_MAX = "18446744073709551615"
local MAX_SAFE_INTEGER = 9007199254740991

local function validCanonicalId(kind, id)
    if kind == "prop" then
        if type(id) ~= "string" then return false end
        if #id < 1 or #id > 20 or id:match("^[1-9]%d*$") == nil then return false end
        if #id == 20 and id > U64_MAX then return false end
        return true
    end
    if type(id) ~= "number" then return false end
    return finite(id) and id > 0 and id % 1 == 0 and id <= MAX_SAFE_INTEGER
end

local function validParent(value)
    if value == nil then return true end
    if type(value) ~= "table" or not PARENT_TYPES_CANONICAL[value.type] then return false end
    return validCanonicalId(value.type, value.id)
end

local function validPlacement(value)
    if type(value) ~= "table" then return false, "invalid_placement" end
    if not validVector(value.position, 1000000) then return false, "invalid_placement_position" end
    if not validRotation(value.rotation) then return false, "invalid_placement_rotation" end
    if not finite(value.width) or value.width < 0.05 or value.width > 40 then return false, "invalid_placement_width" end
    if not finite(value.height) or value.height < 0.05 or value.height > 40 then return false, "invalid_placement_height" end
    if value.radius ~= nil and (not finite(value.radius) or value.radius < 1 or value.radius > 500) then
        return false, "invalid_placement_radius"
    end
    if value.access ~= nil and value.access ~= "public" and value.access ~= "granted" then
        return false, "invalid_placement_access"
    end
    if value.model ~= nil and value.model ~= "surface" and value.model ~= "panel" then
        return false, "invalid_placement_model"
    end
    if not validParent(value.parent) then return false, "invalid_placement_parent" end
    return true
end

local function validHousing(value)
    if type(value) ~= "table" then return false, "invalid_housing" end
    local model = value.model
    if type(model) ~= "string" or #model == 0 or #model > 64 or model:match("^[%w_%-%.:]+$") == nil then
        return false, "invalid_housing_model"
    end
    if value.offset ~= nil then
        if not validVector(value.offset, 10) then return false, "invalid_housing_offset" end
    end
    if value.yaw ~= nil and (not finite(value.yaw) or math.abs(value.yaw) > 360) then
        return false, "invalid_housing_yaw"
    end
    return true
end

local function cleanHousing(value)
    if type(value) ~= "table" then return nil end
    local housing = {
        model = value.model,
        yaw = finite(value.yaw) and clamp(value.yaw, -360, 360) or 0,
    }
    -- An omitted offset stays omitted: the service's own default is the setback
    -- behind the lens, and materializing a zero here would silently override it.
    local offset = value.offset
    if type(offset) == "table" then
        housing.offset = {
            x = finite(offset.x) and clamp(offset.x, -10, 10) or 0,
            y = finite(offset.y) and clamp(offset.y, -10, 10) or 0,
            z = finite(offset.z) and clamp(offset.z, -10, 10) or 0,
        }
    end
    return housing
end

local function validCameraSpec(value)
    if type(value) ~= "table" then return false, "invalid_camera" end
    if not validVector(value.position, 1000000) then return false, "invalid_camera_position" end
    if not validRotation(value.rotation) then return false, "invalid_camera_rotation" end
    if value.fov ~= nil and (not finite(value.fov) or value.fov < 1 or value.fov > 120) then return false, "invalid_camera_fov" end
    if value.range ~= nil and (not finite(value.range) or value.range < 1 or value.range > 500) then return false, "invalid_camera_range" end
    if value.housing ~= nil then
        local ok, reason = validHousing(value.housing)
        if not ok then return false, reason end
    end
    return true
end

local function cleanCameraSpec(value)
    return {
        position = { x = value.position.x, y = value.position.y, z = value.position.z },
        rotation = cleanRotation(value.rotation),
        fov = finite(value.fov) and clamp(value.fov, 1, 120) or 60,
        range = finite(value.range) and clamp(value.range, 1, 500) or 100,
        housing = cleanHousing(value.housing),
    }
end

local function cleanPlacement(value)
    local rotation = cleanRotation(value.rotation)
    local model = value.model == "panel" and "panel" or "surface"
    local placement = {
        position = { x = value.position.x, y = value.position.y, z = value.position.z },
        rotation = rotation,
        width = value.width, height = value.height,
        model = model,
        radius = value.radius ~= nil and clamp(value.radius, 1, 500) or DEFAULT_RADIUS,
        access = value.access == "public" and "public" or "granted",
    }
    if value.parent then
        placement.parent = { type = value.parent.type, id = value.parent.id }
    end
    return placement
end

local function slugFor(name)
    local slug = tostring(name):lower():gsub("[^%w]+", "-"):gsub("^%-+", ""):gsub("%-+$", ""):sub(1, 40)
    if slug == "" then slug = "screen" end
    return slug
end

local function allocateKey(name)
    local base = slugFor(name)
    if byKey[base] == nil then return base end
    for index = 2, 64 do
        local candidate = base .. "-" .. tostring(index)
        if byKey[candidate] == nil then return candidate end
    end
    return nil, "key_space_exhausted"
end

-- ---------------------------------------------------------------------------
-- Persistence
-- ---------------------------------------------------------------------------

local function persisted(record)
    return {
        key = record.key, name = record.name, model = record.model,
        cameraKey = record.cameraKey, cameraOwned = record.cameraOwned, cameraSpec = record.cameraSpec,
        placement = record.placement, localPlacement = record.localPlacement, parent = record.parent,
        bucket = record.bucket, updatedAt = record.updatedAt,
        -- Session ids are recycled after a server restart. Private grants are
        -- runtime-only; never persist or restore an author's numeric player id.
    }
end

-- What the live screen is actually placed at. While a parent captured in THIS
-- process is still in force, that is the local pose plus the parent, which is
-- what makes the panel follow a moving vehicle; once the process restarts (or a
-- save cleared the parent) it is the stored world pose with no parent.
local function livePlacement(record)
    if record.parentLive and record.parent and record.localPlacement then
        local placement = {}
        for key, value in pairs(record.localPlacement) do placement[key] = value end
        placement.parent = { type = record.parent.type, id = record.parent.id }
        return placement
    end
    local placement = {}
    for key, value in pairs(record.placement) do placement[key] = value end
    placement.parent = nil
    return placement
end

local function storeSave()
    local payload = { version = STORE_VERSION, definitions = {} }
    for _, record in ipairs(definitions) do payload.definitions[#payload.definitions + 1] = persisted(record) end
    local text = json.encode(payload)
    if type(text) ~= "string" then return false, "encode_failed" end
    if #text > STORE_MAX_BYTES then return false, "store_full" end
    local ok, reason = Open77.kvp.set(STORE_KEY, text)
    if ok ~= true then return false, tostring(reason or "store_unavailable") end
    return true
end

local function storeLoad()
    local text, reason = Open77.kvp.get(STORE_KEY)
    if text == nil then
        if reason then log("definition store unreadable: " .. tostring(reason)) end
        return 0
    end
    local payload = json.decode(text)
    if type(payload) ~= "table" or payload.version ~= STORE_VERSION or type(payload.definitions) ~= "table" then
        log("definition store has an unusable shape; keeping it, loading nothing")
        return 0
    end
    local loaded = 0
    for _, raw in ipairs(payload.definitions) do
        if type(raw) == "table" and type(raw.key) == "string" and raw.key:match(KEY_PATTERN)
            and type(raw.cameraKey) == "string" and validPlacement(raw.placement)
            and type(raw.name) == "string" and validCameraSpec(raw.cameraSpec) then
            local record = {
                key = raw.key:sub(1, 48), name = raw.name:sub(1, 48),
                model = raw.placement.model == "panel" and "panel" or "surface",
                cameraKey = raw.cameraKey:sub(1, 48), cameraOwned = raw.cameraOwned == true,
                cameraSpec = cleanCameraSpec(raw.cameraSpec),
                placement = cleanPlacement(raw.placement),
                bucket = finite(raw.bucket) and raw.bucket or 0,
                updatedAt = finite(raw.updatedAt) and raw.updatedAt or 0,
                author = nil,
            }
            -- Runtime parent ids are not portable across restarts. Restore the
            -- world pose and require explicit parent reselection.
            record.placement.parent = nil
            local parent = raw.parent
            if type(parent) == "table" and PARENT_TYPES_CANONICAL[parent.type] and validParent({ type = parent.type, id = parent.id }) then
                record.lastParent = { type = parent.type, id = parent.id }
                record.notice = "parent_requires_reselection"
            end
            if type(raw.localPlacement) == "table" and validPlacement(raw.localPlacement) then
                local localPlacement = cleanPlacement(raw.localPlacement)
                localPlacement.parent = nil
                record.localPlacement = localPlacement
            end
            if record and loaded < MAX_DEFINITIONS and byKey[record.key] == nil then
                definitions[#definitions + 1] = record
                byKey[record.key] = record
                loaded = loaded + 1
            end
        end
    end
    return loaded
end

-- ---------------------------------------------------------------------------
-- Service adapter
-- ---------------------------------------------------------------------------

local function cameraIndex(svc)
    local byName, byId = {}, {}
    local rows = svc.list(OWNER, GENERATION)
    if type(rows) == "table" then
        for _, camera in ipairs(rows) do
            if type(camera) == "table" and camera.key then
                byName[camera.key] = camera
                byId[camera.id] = camera
            end
        end
    end
    return byName, byId
end

-- Reconstruct missing owned objects and retain the service's refusal reason.
local function ensureLive(record, camerasByName)
    local svc = service()
    if not svc then
        record.state, record.reason = "failed", "service_unavailable"
        return false
    end
    local cameraId = record.cameraId
    if cameraId then
        local snapshot = svc.get(OWNER, GENERATION, cameraId)
        if type(snapshot) ~= "table" then cameraId = nil end
    end
    if not cameraId then
        local known = camerasByName[record.cameraKey]
        if known then
            cameraId = known.id
        elseif record.cameraOwned then
            local created, reason = svc.create(OWNER, GENERATION, {
                key = record.cameraKey,
                position = record.cameraSpec.position,
                rotation = record.cameraSpec.rotation,
                fov = record.cameraSpec.fov, range = record.cameraSpec.range,
                bucket = record.bucket, enabled = true,
                housing = record.cameraSpec.housing,
            })
            if not created then
                record.state, record.reason = "failed", tostring(reason)
                return false
            end
            cameraId = created.id
            camerasByName[record.cameraKey] = created
        else
            record.state, record.reason = "missing", "camera_unavailable"
            return false
        end
    end
    record.cameraId = cameraId
    if record.screenId then
        local snapshot = svc.getScreen(OWNER, GENERATION, record.screenId)
        if type(snapshot) ~= "table" then record.screenId = nil end
    end
    if not record.screenId then
        local placement = livePlacement(record)
        local screenId, reason = svc.createScreen(OWNER, GENERATION, cameraId, {
            position = placement.position, rotation = placement.rotation,
            width = placement.width, height = placement.height,
            model = record.model, radius = placement.radius, access = placement.access,
            parent = placement.parent,
        })
        if not screenId and placement.parent then
            -- If the parented placement is refused, retain the saved world pose
            -- and report that the parent relationship was not restored.
            record.parentLive = false
            record.notice = "parent_not_supported_world_pose_kept"
            placement = livePlacement(record)
            screenId, reason = svc.createScreen(OWNER, GENERATION, cameraId, {
                position = placement.position, rotation = placement.rotation,
                width = placement.width, height = placement.height,
                model = record.model, radius = placement.radius, access = placement.access,
            })
        end
        if not screenId then
            record.state, record.reason = "failed", tostring(reason)
            return false
        end
        record.screenId = screenId
        record.screenCameraId = cameraId
    end
    record.state, record.reason = "live", nil
    -- Rebuilt screens need their author's grant restored.
    if record.placement.access == "granted" and record.author then
        svc.setAccess(OWNER, GENERATION, cameraId, record.author, { view = true })
    end
    return true
end

local function viewerStateOf(record, player)
    local svc = service()
    if not player then return nil end
    if not svc then return "unavailable", "service_unavailable" end
    if not record.screenId then return "unavailable", record.reason or "screen_unavailable" end
    local snapshot = svc.getScreen(OWNER, GENERATION, record.screenId)
    if type(snapshot) ~= "table" then return "missing", "screen_unavailable" end
    -- getScreen reports viewers as an array of {playerId, state, reason},
    -- sorted by player id, not as a map.
    local viewers = snapshot.viewers
    if type(viewers) == "table" then
        for _, entry in ipairs(viewers) do
            if type(entry) == "table" and tonumber(entry.playerId) == player then
                return entry.state or "pending", entry.reason
            end
        end
    end
    return "unavailable", "not_in_range_or_not_granted"
end

local function draftFromRecord(record)
    local camera = record.cameraSpec
    local svc = service()
    if svc and record.cameraId then
        local snapshot = svc.get(OWNER, GENERATION, record.cameraId)
        if type(snapshot) == "table" and validCameraSpec(snapshot) then
            camera = cleanCameraSpec(snapshot)
            record.cameraSpec = camera
        end
    end
    local live = livePlacement(record)
    return {
        key = record.key, name = record.name, model = record.model,
        cameraKey = not record.cameraOwned and record.cameraKey or nil,
        camera = camera,
        -- The housing rides beside the pose rather than inside it: the pose is
        -- what the editor edits, the housing is what the service puts on a wall.
        housing = camera.housing,
        lastParent = record.lastParent or (not record.parentLive and record.parent or nil),
        placement = {
            position = { x = live.position.x, y = live.position.y, z = live.position.z },
            rotation = cleanRotation(live.rotation),
            width = live.width, height = live.height,
            radius = live.radius, access = live.access,
            parent = live.parent and { type = live.parent.type, id = live.parent.id } or nil,
        },
        depth = DEFAULT_DEPTH,
    }
end

local function definitionRows(player)
    local rows = {}
    for _, record in ipairs(definitions) do
        local live = livePlacement(record)
        local row = {
            key = record.key, name = record.name, model = record.model,
            cameraKey = record.cameraKey, cameraId = record.cameraId, screenId = record.screenId,
            state = record.state or "pending", reason = record.reason,
            notice = record.notice,
            lastParent = record.lastParent and { type = record.lastParent.type, id = record.lastParent.id } or nil,
            width = live.width, height = live.height,
            radius = live.radius, access = live.access,
            parent = live.parent and { type = live.parent.type, id = live.parent.id } or nil,
            position = { x = live.position.x, y = live.position.y, z = live.position.z },
            rotation = cleanRotation(live.rotation),
        }
        local session = sessions[player]
        if session and record.key == session.editingKey then
            row.viewerState, row.viewerReason = viewerStateOf(record, player)
        end
        rows[#rows + 1] = row
    end
    return rows
end

local function cameraRows()
    local svc = service()
    local rows = {}
    local list = svc and svc.list(OWNER, GENERATION)
    if type(list) == "table" then
        for _, camera in ipairs(list) do
            if #rows >= MAX_CAMERA_ROWS then break end
            if type(camera) == "table" and camera.key then
                rows[#rows + 1] = {
                    key = camera.key, id = camera.id, bucket = camera.bucket,
                    position = camera.position, rotation = camera.rotation,
                    fov = camera.fov, range = camera.range,
                }
            end
        end
    end
    return rows
end

local function pushDefinitions(player)
    TriggerClientEvent("open77:remoteCamera:editor:definitions", player, { rows = definitionRows(player) })
end

local function pushCameras(player)
    TriggerClientEvent("open77:remoteCamera:editor:cameras", player, { rows = cameraRows() })
end

-- ---------------------------------------------------------------------------
-- Sessions and the command
-- ---------------------------------------------------------------------------

local function playerReady(player)
    if player == nil or player <= 0 then return false, "player_required", nil end
    local position = Open77.players.position(player)
    if position == nil then return false, "player_not_ready", nil end
    local life = Open77.players.getLifeState(player)
    if type(life) == "table" and (life.phase == "dead" or life.phase == "respawnpending" or life.phase == "revivepending") then
        return false, "player_not_ready", position.bucket
    end
    return true, "ok", position.bucket
end

local function aclAllowed(player)
    if Open77.acl == nil or type(Open77.acl.isAllowed) ~= "function" then return false, "acl_unavailable" end
    if Open77.acl.isAllowed(player, "command.remote-camera.editor") == true then return true, nil end
    return false, "permission_denied:command.remote-camera.editor"
end

local function closeSession(player, reason, notify)
    if not sessions[player] then return end
    sessions[player] = nil
    if notify then TriggerClientEvent("open77:remoteCamera:editor:closed", player, { reason = reason }) end
    log(("session closed player=%d reason=%s"):format(player, tostring(reason)))
end

local function openSession(player, key)
    local ready, reason, bucket = playerReady(player)
    if not ready then return nil, reason end
    local allowed, aclReason = aclAllowed(player)
    if not allowed then return nil, aclReason end
    local record
    if key then
        record = byKey[key]
        if not record then return nil, "unknown_key" end
        if record.state ~= "live" then
            local svc = service()
            local camerasByName = {}
            if svc then camerasByName = select(1, cameraIndex(svc)) end
            ensureLive(record, camerasByName)
        end
    end
    local existing = sessions[player]
    if existing and key == nil then
        -- The command was run again while the editor is open: that is a refocus
        -- and a refresh, never a new draft. The token is unchanged, so any
        -- message already in flight from this client stays valid.
        existing.bucket = bucket
        existing.screenId = existing.editingKey and byKey[existing.editingKey] and byKey[existing.editingKey].screenId or existing.screenId
        TriggerClientEvent("open77:remoteCamera:editor:open", player, {
            session = { token = existing.token, bucket = bucket, editingKey = existing.editingKey, generation = tostring(GENERATION) },
            definitions = definitionRows(player),
            cameras = cameraRows(),
            limits = { maxDefinitions = MAX_DEFINITIONS },
        })
        return true
    end
    sequence = sequence + 1
    local session = {
        token = tostring(GENERATION) .. ":" .. tostring(sequence),
        bucket = bucket, editingKey = record and record.key or nil,
        screenId = record and record.screenId or nil,
        tokens = MESSAGE_CAPACITY, refillAt = now(), openedAt = now(),
    }
    sessions[player] = session
    TriggerClientEvent("open77:remoteCamera:editor:open", player, {
        session = { token = session.token, bucket = bucket, editingKey = session.editingKey, generation = tostring(GENERATION) },
        draft = record and draftFromRecord(record) or nil,
        definitions = definitionRows(player),
        cameras = cameraRows(),
        limits = { maxDefinitions = MAX_DEFINITIONS },
    })
    log(("session opened player=%d bucket=%s editing=%s"):format(player, tostring(bucket), tostring(session.editingKey)))
    return true
end

local function consumeMessage(player)
    local session = sessions[player]
    if not session then return false end
    local clock = now()
    local refill = (clock - session.refillAt) * MESSAGE_REFILL
    if refill > 0 then
        session.tokens = math.min(MESSAGE_CAPACITY, session.tokens + refill)
        session.refillAt = clock
    end
    if session.tokens < 1 then return false end
    session.tokens = session.tokens - 1
    return true
end

-- ---------------------------------------------------------------------------
-- Mutations
-- ---------------------------------------------------------------------------

-- Shared sources retire only after their last definition releases them.
-- Either id or owner-local key identifies a reference.
local function referencingDefinition(camera, except)
    for _, other in ipairs(definitions) do
        if other ~= except and (other.cameraId == camera.id
            or (camera.key ~= nil and other.cameraKey == camera.key)) then
            return other
        end
    end
    return nil
end

-- Hand an editor-created source to a definition that still wants it, or remove
-- it when none does. A borrowed camera never reaches here: `cameraOwned` is the
-- record's own statement that this resource made it.
local function releaseCamera(record, camera)
    local svc = service()
    if not svc or not camera or not camera.id then return end
    local heir = referencingDefinition(camera, record)
    if heir then
        heir.cameraId, heir.cameraKey, heir.cameraOwned = camera.id, camera.key, true
        local snapshot = svc.get(OWNER, GENERATION, camera.id)
        if type(snapshot) == "table" and validCameraSpec(snapshot) then
            heir.cameraSpec = cleanCameraSpec(snapshot)
        elseif validCameraSpec(camera.spec) then
            heir.cameraSpec = cleanCameraSpec(camera.spec)
        end
        return
    end
    local removed, reason = svc.remove(OWNER, GENERATION, camera.id)
    if removed ~= true and tostring(reason) ~= "not_found" then
        log(("source %s left behind: %s"):format(tostring(camera.key), tostring(reason)))
    end
end

-- Snapshot metadata before a save so service refusal can restore it.
local function stagedDefinition(record)
    return {
        name = record.name, model = record.model, bucket = record.bucket,
        placement = record.placement, localPlacement = record.localPlacement,
        parent = record.parent, lastParent = record.lastParent, parentLive = record.parentLive,
        notice = record.notice, updatedAt = record.updatedAt,
        cameraKey = record.cameraKey, cameraOwned = record.cameraOwned,
        cameraId = record.cameraId, cameraSpec = record.cameraSpec,
    }
end

local function restoreDefinition(record, staged)
    if not staged then return end
    for field, value in pairs(staged) do record[field] = value end
end

-- Roll back sources created or moved by a refused save. Source ownership
-- transfers are committed only after the screen succeeds.
local function rollbackCamera(change, staged)
    local svc = service()
    if not svc or not change then return nil end
    if change.created then
        local removed, reason = svc.remove(OWNER, GENERATION, change.created)
        -- Gone is gone: a source that is already not there is not a leak.
        if removed == true or tostring(reason) == "not_found" then return true end
        log(("source %s created by a refused save could not be removed: %s")
            :format(tostring(change.created), tostring(reason)))
        return false, tostring(reason)
    end
    if change.moved and staged and type(staged.cameraSpec) == "table" and validCameraSpec(staged.cameraSpec) then
        -- Report a refused rollback; the live source may then differ from storage.
        local ok, reason = svc.configure(OWNER, GENERATION, change.moved, {
            position = staged.cameraSpec.position, rotation = staged.cameraSpec.rotation,
            fov = staged.cameraSpec.fov, range = staged.cameraSpec.range, bucket = staged.bucket,
        })
        if ok ~= true then
            log(("source %s could not be put back at the saved pose: %s"):format(tostring(change.moved), tostring(reason)))
        end
    end
    return nil
end

-- Return the source id and the changes the caller must commit or roll back.
local function applyCamera(record, spec, bucket, reuseKey)
    local svc = service()
    if not svc then return nil, "service_unavailable", nil end
    local change = {}
    if reuseKey then
        local byName = select(1, cameraIndex(svc))
        local camera = byName[reuseKey]
        if not camera then return nil, "camera_not_found", nil end
        -- A different source leaves the old one unused here, but it is not
        -- released until the screen save succeeds.
        if record.cameraOwned and record.cameraId and record.cameraId ~= camera.id then
            change.dropped = { id = record.cameraId, key = record.cameraKey, spec = record.cameraSpec }
        end
        record.cameraOwned = record.cameraOwned and record.cameraId == camera.id and record.cameraKey == reuseKey
        record.cameraKey = reuseKey
        local snapshot = svc.get(OWNER, GENERATION, camera.id)
        if type(snapshot) == "table" and validCameraSpec(snapshot) then record.cameraSpec = cleanCameraSpec(snapshot) end
        record.cameraId = camera.id
        return camera.id, nil, change
    end
    local ownedKey = record.cameraOwned and record.cameraKey or (CAMERA_PREFIX .. record.key)
    if record.cameraId and record.cameraOwned then
        local ok, reason = svc.configure(OWNER, GENERATION, record.cameraId, {
            position = spec.position, rotation = spec.rotation, fov = spec.fov, range = spec.range, bucket = bucket,
            -- `false` is the service's removal sentinel, and the spec is the whole
            -- desired state: a spec without a housing takes one off the wall.
            housing = spec.housing or false,
        })
        if ok then
            record.cameraKey, record.cameraOwned, record.cameraSpec = ownedKey, true, spec
            change.moved = record.cameraId
            return record.cameraId, nil, change
        end
        if tostring(reason) ~= "not_found" then
            -- A refusal is the service's answer, not a licence to make a second
            -- source beside the one that is already there.
            return nil, tostring(reason), nil
        end
        -- The camera is gone under us; the create below is the recovery.
        record.cameraId = nil
    end
    local created, reason = svc.create(OWNER, GENERATION, {
        key = ownedKey, position = spec.position, rotation = spec.rotation,
        fov = spec.fov, range = spec.range, bucket = bucket, enabled = true,
        housing = spec.housing,
    })
    if not created then return nil, tostring(reason), nil end
    record.cameraId, record.cameraKey, record.cameraOwned, record.cameraSpec = created.id, ownedKey, true, spec
    change.created = created.id
    return created.id, nil, change
end

-- A canonical parent is a live relationship while this process holds it: the
-- patch carries the parent and the LOCAL pose, so the panel follows a moving
-- vehicle. The stored world pose is what a restart restores. The patch is flat
-- and sparse, and `cameraId` is sent only when the source actually moved.
local function applyScreen(record, cameraId, desiredLive, desiredWorld, cleared, warnings)
    local svc = service()
    if not svc then return nil, "service_unavailable", warnings end
    local function attempt(withParent)
        local placement = (withParent and desiredLive) or desiredWorld
        local flat = {
            position = placement.position, rotation = placement.rotation,
            width = placement.width, height = placement.height,
            model = record.model, radius = placement.radius, access = placement.access,
        }
        if withParent and placement.parent then
            flat.parent = { type = placement.parent.type, id = placement.parent.id }
        end
        if record.screenId then
            if record.screenCameraId ~= cameraId then flat.cameraId = cameraId end
            -- A detach is only meaningful against an existing screen, and the
            -- patch carries the pose in the new (world) frame with it.
            if not withParent and cleared then flat.parent = false end
            local ok, reason = svc.updateScreen(OWNER, GENERATION, record.screenId, flat)
            if ok then
                record.screenCameraId = cameraId
                return record.screenId, nil
            end
            if tostring(reason) == "not_found" then
                record.screenId = nil
            else
                -- A refusal is the service's answer, not a licence to make a
                -- second screen beside the first one. Report it and keep both.
                return nil, tostring(reason)
            end
        end
        -- Source switches and detach sentinels belong to updateScreen, not a
        -- new placement (including recovery after a stale screen disappeared).
        flat.cameraId = nil
        if flat.parent == false then flat.parent = nil end
        local screenId, reason = svc.createScreen(OWNER, GENERATION, cameraId, flat)
        if not screenId then return nil, tostring(reason) end
        record.screenId, record.screenCameraId = screenId, cameraId
        return screenId, nil
    end
    if desiredLive and desiredLive.parent then
        local screenId, reason = attempt(true)
        if screenId then
            record.parentLive = true
            return screenId, nil, warnings
        end
        -- The service refused the parent: fall back to the world pose once, and
        -- keep saying so rather than pretending the panel follows anything.
        record.parentLive = false
        record.notice = "parent_not_supported_world_pose_kept"
        warnings[#warnings + 1] = "parent_not_supported_world_pose_kept"
        log(("parented placement refused for %s: %s; kept world pose"):format(record.key, tostring(reason)))
    end
    local screenId, reason = attempt(false)
    if not screenId then return nil, tostring(reason), warnings end
    record.parentLive = false
    return screenId, nil, warnings
end

local function handleSave(player, payload)
    local ready, reason, bucket = playerReady(player)
    if not ready then return notice(player, false, "Save refused: " .. tostring(reason) .. ".") end
    local allowed, aclReason = aclAllowed(player)
    if not allowed then return notice(player, false, "Save refused: " .. tostring(aclReason) .. ".") end
    local name = type(payload.name) == "string" and payload.name:gsub("%s+$", ""):gsub("^%s+", "") or ""
    if #name < 1 or #name > 48 then return notice(player, false, "Give the placement a name of 1-48 characters.") end
    local placementOk, placementReason = validPlacement(payload.placement)
    if not placementOk then return notice(player, false, "Save refused: " .. tostring(placementReason) .. ".") end
    local cameraOk, cameraReason = validCameraSpec(payload.camera)
    if not cameraOk then return notice(player, false, "Save refused: " .. tostring(cameraReason) .. ".") end
    local reuseKey
    if payload.cameraKey ~= nil then
        if type(payload.cameraKey) ~= "string" or not payload.cameraKey:match(KEY_PATTERN) then
            return notice(player, false, "Save refused: invalid camera key.")
        end
        reuseKey = payload.cameraKey:sub(1, 48)
    end
    local existing = payload.key ~= nil and byKey[payload.key] or nil
    if payload.key ~= nil and existing == nil then
        return notice(player, false, "Save refused: unknown key " .. tostring(payload.key) .. ".")
    end
    local record = existing
    if record == nil then
        if #definitions >= MAX_DEFINITIONS then
            return notice(player, false, ("Save refused: this resource already holds %d placements."):format(MAX_DEFINITIONS))
        end
        local key, keyReason = allocateKey(name)
        if not key then return notice(player, false, "Save refused: " .. tostring(keyReason) .. ".") end
        record = {
            key = key, name = name, model = payload.model == "panel" and "panel" or "surface",
            cameraKey = CAMERA_PREFIX .. key, cameraOwned = true,
            placement = cleanPlacement(payload.placement), bucket = bucket, updatedAt = now(),
        }
    end
    local placement = cleanPlacement(payload.placement)
    local desiredLive, desiredWorld, cleared
    local hasParent = placement.parent ~= nil
    if hasParent then
        -- The local pose is what a live parent follows, and the world pose is
        -- what a restart restores. Both are kept; without the world pose there
        -- is nothing honest to restore, so the save is refused.
        if type(payload.world) ~= "table"
            or not validVector(payload.world.position, 1000000) or not validRotation(payload.world.rotation) then
            return notice(player, false, "Save refused: the parent frame could not be resolved; snap again or clear the parent.")
        end
        desiredLive = {}
        for key, value in pairs(placement) do desiredLive[key] = value end
        desiredWorld = {
            position = { x = payload.world.position.x, y = payload.world.position.y, z = payload.world.position.z },
            rotation = cleanRotation(payload.world.rotation),
            width = placement.width, height = placement.height,
            radius = placement.radius, access = placement.access, model = placement.model,
        }
    else
        desiredWorld = placement
        desiredWorld.model = payload.model == "panel" and "panel" or "surface"
    end
    cleared = (record.parentLive and record.parent ~= nil) and placement.parent == nil
    -- Everything below writes the record and the live source. Keep what the
    -- record is now so a refusal can put it back rather than commit half a save.
    local staged = existing and stagedDefinition(record) or nil
    record.name = name
    record.model = payload.model == "panel" and "panel" or "surface"
    record.bucket = bucket
    record.placement = desiredWorld
    record.localPlacement = desiredLive
    record.parent = placement.parent and { type = placement.parent.type, id = placement.parent.id } or nil
    record.lastParent = record.parent and { type = record.parent.type, id = record.parent.id } or nil
    record.notice = nil
    record.updatedAt = now()
    local cameraId, cameraError, cameraChange = applyCamera(record, cleanCameraSpec(payload.camera), bucket, reuseKey)
    if not cameraId then
        restoreDefinition(record, staged)
        return notice(player, false, "Save refused by the service: " .. tostring(cameraError) .. ".")
    end
    local warnings = {}
    local screenId, screenError = applyScreen(record, cameraId, desiredLive, desiredWorld, cleared, warnings)
    if not screenId then
        local cleaned, cleanupReason = rollbackCamera(cameraChange, staged)
        restoreDefinition(record, staged)
        if cameraChange and cameraChange.created and cleaned ~= true then
            return notice(player, false, "Save refused: " .. tostring(screenError) ..
                ". The source this save created could not be removed: " .. tostring(cleanupReason) .. ".")
        end
        local suffix = (cameraChange and cameraChange.created) and " The source this save created was removed."
            or (staged and " The saved definition is unchanged." or " Nothing was saved.")
        return notice(player, false, "Save refused: " .. tostring(screenError) .. "." .. suffix)
    end
    -- The save is real: a source it repointed the record away from is now free
    -- to be handed to another definition that still uses it, or retired.
    if cameraChange and cameraChange.dropped then releaseCamera(record, cameraChange.dropped) end
    if type(payload.previewParent) == "table"
        and (payload.previewParent.type == "localProp" or payload.previewParent.type == "entity") then
        -- A vanilla prop or an unowned body has no identity the service can
        -- follow: it was a preview, and the record says so.
        record.notice = "parent_preview_only_not_saved"
        warnings[#warnings + 1] = "parent_preview_only_not_saved"
    end
    if existing == nil then
        -- Only a placement that actually exists live is added to the list.
        definitions[#definitions + 1] = record
        byKey[record.key] = record
    end
    warnings = warnings or {}
    record.author = player
    if record.placement.access == "granted" then
        local granted, grantReason = service().setAccess(OWNER, GENERATION, cameraId, player, { view = true })
        if granted ~= true then
            warnings[#warnings + 1] = "author_grant_failed:" .. tostring(grantReason)
        end
    end
    local saved, storeReason = storeSave()
    if not saved then
        warnings[#warnings + 1] = "not_persisted:" .. tostring(storeReason)
    end
    local session = sessions[player]
    if session then session.screenId = screenId end
    local viewerState, viewerReason = viewerStateOf(record, player)
    local rows = definitionRows(player)
    TriggerClientEvent("open77:remoteCamera:editor:saved", player, {
        ok = true, definition = draftFromRecord(record), screenId = screenId, cameraId = cameraId,
        definitions = rows, warnings = warnings, viewerState = viewerState, viewerReason = viewerReason,
        stored = saved == true,
    })
    log(("saved %s screen=%s camera=%s persisted=%s warnings=%s")
        :format(record.key, tostring(screenId), tostring(cameraId), tostring(saved), tostring(#warnings)))
    pushCameras(player)
end

-- A borrowed camera is not the editor's to remove; an owned one is retired only
-- when this was the last definition using it, so a screen that reuses it keeps
-- working. Lifecycle responsibility moves to that surviving definition.
local function removeRecord(record)
    local svc = service()
    if svc then
        if record.screenId then svc.removeScreen(OWNER, GENERATION, record.screenId) end
        if record.cameraId and record.cameraOwned then
            releaseCamera(record, { id = record.cameraId, key = record.cameraKey, spec = record.cameraSpec })
        end
    end
    byKey[record.key] = nil
    for index = #definitions, 1, -1 do
        if definitions[index] == record then table.remove(definitions, index) end
    end
end

local function handleDelete(player, payload)
    local key = payload.key
    if type(key) ~= "string" then return end
    local record = byKey[key]
    if not record then return notice(player, false, "Delete refused: unknown key " .. tostring(key) .. ".") end
    removeRecord(record)
    local saved, storeReason = storeSave()
    local session = sessions[player]
    if session and session.editingKey == key then
        session.editingKey, session.screenId = nil, nil
    end
    TriggerClientEvent("open77:remoteCamera:editor:deleted", player, {
        ok = true, key = key, definitions = definitionRows(player),
        stored = saved == true, storeReason = saved and nil or storeReason,
    })
    log(("deleted %s persisted=%s"):format(key, tostring(saved)))
    pushCameras(player)
end

local function handleReopen(player, payload)
    local key = payload.key
    if type(key) ~= "string" then return end
    local record = byKey[key]
    if not record then return notice(player, false, "Reopen refused: unknown key " .. tostring(key) .. ".") end
    local svc = service()
    local camerasByName = {}
    if svc then camerasByName = select(1, cameraIndex(svc)) end
    ensureLive(record, camerasByName)
    local session = sessions[player]
    if session then
        session.editingKey = record.key
        session.screenId = record.screenId
    end
    local viewerState, viewerReason = viewerStateOf(record, player)
    TriggerClientEvent("open77:remoteCamera:editor:draft", player, {
        draft = draftFromRecord(record), message = "Editing " .. record.key .. ". Changes stay local until SAVE.",
        viewerState = viewerState, viewerReason = viewerReason,
    })
    pushDefinitions(player)
    log(("reopened %s state=%s"):format(record.key, tostring(record.state)))
end

RegisterNetEvent("open77:remoteCamera:editor:action", function(payload)
    local player = tonumber(source)
    if not player or player <= 0 or type(payload) ~= "table" then return end
    -- A revoked operator must not keep an open editor: the transport gate on
    -- the command line does not cover this event, so it is re-checked here.
    local allowed, reason = aclAllowed(player)
    if not allowed then
        closeSession(player, reason, true)
        return
    end
    local session = sessions[player]
    if not session then return end
    if payload.token ~= session.token then return end
    if not consumeMessage(player) then
        return notice(player, false, "Too many editor messages; slow down.")
    end
    local ok, err
    if payload.action == "close" then
        closeSession(player, "closed_by_client", false)
        return
    elseif payload.action == "save" then
        ok, err = pcall(handleSave, player, payload)
    elseif payload.action == "delete" then
        ok, err = pcall(handleDelete, player, payload)
    elseif payload.action == "reopen" then
        ok, err = pcall(handleReopen, player, payload)
    else
        return
    end
    if ok == false then
        -- A handler that unwound must not leave the page waiting on a save it
        -- will never hear about.
        log(("action %s failed: %s"):format(tostring(payload.action), tostring(err)))
        notice(player, false, "The editor failed on the server: " .. tostring(err) .. ". Nothing was saved.")
    end
end)

-- ---------------------------------------------------------------------------
-- Reconcile loops
-- ---------------------------------------------------------------------------

local function reconcileAll()
    local svc = service()
    if not svc then return 0, 0 end
    local camerasByName = select(1, cameraIndex(svc))
    local live, failed = 0, 0
    for _, record in ipairs(definitions) do
        local ok = ensureLive(record, camerasByName)
        if ok then live = live + 1 else failed = failed + 1 end
    end
    return live, failed
end

CreateThread(function()
    Wait(500)
    local loaded = storeLoad()
    if loaded > 0 then log(("loaded %d placement definition(s)"):format(loaded)) end
    Wait(1500)
    local live, failed = reconcileAll()
    if #definitions > 0 then
        log(("reconcile: %d live, %d not live, %d total"):format(live, failed, #definitions))
    end
    local nextReconcile, nextPresentation = now() + RECONCILE_INTERVAL, now() + PRESENTATION_INTERVAL
    while true do
        local clock = now()
        if clock >= nextReconcile then
            nextReconcile = clock + RECONCILE_INTERVAL
            local changed = false
            local before = {}
            for _, record in ipairs(definitions) do before[record.key] = tostring(record.screenId) .. ":" .. tostring(record.cameraId) end
            reconcileAll()
            for _, record in ipairs(definitions) do
                if before[record.key] ~= tostring(record.screenId) .. ":" .. tostring(record.cameraId) then changed = true end
            end
            if changed then storeSave() end
        end
        if clock >= nextPresentation then
            nextPresentation = clock + PRESENTATION_INTERVAL
            for player, session in pairs(sessions) do
                if session.screenId then
                    local record = session.editingKey and byKey[session.editingKey] or nil
                    if record and record.screenId == session.screenId then
                        local state, reason = viewerStateOf(record, player)
                        if state ~= session.lastViewerState or reason ~= session.lastViewerReason then
                            session.lastViewerState, session.lastViewerReason = state, reason
                            TriggerClientEvent("open77:remoteCamera:editor:presentation", player, {
                                key = record.key, screenId = record.screenId, state = state or "unknown", reason = reason,
                            })
                        end
                    end
                end
            end
        end
        Wait(250)
    end
end)

AddEventHandler("playerDropped", function()
    local player = tonumber(source)
    if player then sessions[player] = nil end
end)

AddEventHandler("onPlayerBucketChange", function(player)
    player = tonumber(player)
    if player then
        -- A camera pose, a parent and a panel radius are all bucket-scoped
        -- facts; an editor session does not survive the player leaving them.
        closeSession(player, "bucket_changed", true)
    end
end)

AddEventHandler("onResourceStop", function(name)
    if name ~= OWNER then return end
    for player in pairs(sessions) do
        TriggerClientEvent("open77:remoteCamera:editor:closed", player, { reason = "resource_stop" })
    end
    sessions = {}
end)

-- ---------------------------------------------------------------------------
-- Command
-- ---------------------------------------------------------------------------

local function describeRows(player)
    if #definitions == 0 then return "no saved placements" end
    local rows = {}
    for _, record in ipairs(definitions) do
        rows[#rows + 1] = ("%s (%s) state=%s notice=%s camera=%s screen=%s access=%s model=%s")
            :format(record.key, record.name, tostring(record.state), tostring(record.notice), tostring(record.cameraKey),
                tostring(record.screenId), record.placement.access, record.model)
    end
    return table.concat(rows, " | ")
end

local function commandHandler(source, args, raw)
    local player = tonumber(source)
    if not player or player <= 0 then
        return output(source, raw, false, "remote-camera.editor must be run by an authenticated in-game player")
    end
    local sub = args and args[1] and tostring(args[1]):lower() or nil
    if sub == nil then
        local ok, reason = openSession(player, nil)
        if not ok then return output(source, raw, false, "remote-camera.editor refused: " .. tostring(reason)) end
        return output(source, raw, true, "Remote Camera Editor opened (bucket read from the server).")
    end
    if sub == "close" then
        if not sessions[player] then return output(source, raw, false, "no editor session is open") end
        closeSession(player, "closed_by_command", true)
        return output(source, raw, true, "Remote Camera Editor closed.")
    end
    if sub == "snap" then
        if not sessions[player] then return output(source, raw, false, "open the editor first") end
        TriggerClientEvent("open77:remoteCamera:editor:snap", player)
        return output(source, raw, true, "snap requested at the current aim")
    end
    if sub == "list" then
        return output(source, raw, true, describeRows(player))
    end
    if sub == "delete" then
        local key = args[2]
        if type(key) ~= "string" then return output(source, raw, false, "usage: /remote-camera.editor delete <key>") end
        local record = byKey[key]
        if not record then return output(source, raw, false, "unknown key " .. key) end
        removeRecord(record)
        local saved, storeReason = storeSave()
        pushDefinitions(player)
        return output(source, raw, saved == true,
            saved and ("deleted " .. key) or ("deleted " .. key .. " but the store refused: " .. tostring(storeReason)))
    end
    if sub == "reopen" then
        local key = args[2]
        if type(key) ~= "string" then return output(source, raw, false, "usage: /remote-camera.editor reopen <key>") end
        local record = byKey[key]
        if not record then return output(source, raw, false, "unknown key " .. key) end
        local ok, reason = openSession(player, key)
        if not ok then return output(source, raw, false, "reopen refused: " .. tostring(reason)) end
        return output(source, raw, true, "editing " .. key .. " (state=" .. tostring(record.state) .. ")")
    end
    if sub == "open" then
        local key = args[2]
        if type(key) ~= "string" then return output(source, raw, false, "usage: /remote-camera.editor open <key>") end
        local ok, reason = openSession(player, key)
        if not ok then return output(source, raw, false, "open refused: " .. tostring(reason)) end
        return output(source, raw, true, "editing " .. key)
    end
    if sub == "sync" then
        local live, failed = reconcileAll()
        return output(source, raw, true, ("reconciled: %d live, %d not live, %d total"):format(live, failed, #definitions))
    end
    output(source, raw, false, "usage: /remote-camera.editor [open <key> | reopen <key> | list | delete <key> | snap | close | sync]")
end

-- Restricted: the transport requires `command.remote-camera.editor` before this runs,
-- and every net event above re-checks the same permission.
RegisterCommand("remote-camera.editor", function(source, args, raw)
    local ok, err = pcall(commandHandler, source, args, raw)
    if not ok then
        output(source, raw, false, "remote-camera.editor failed: " .. tostring(err))
    end
end, true)

RegisterNetEvent("chat:ready", function()
    TriggerClientEvent("chat:addSuggestions", source, {
        { command = "/remote-camera.editor", help = "Open the Remote Camera Editor (restricted).", parameters = {} },
        { command = "/remote-camera.editor reopen", help = "Edit a saved placement by key.", parameters = { { name = "key" } } },
        { command = "/remote-camera.editor list", help = "List saved placements with their live state." },
        { command = "/remote-camera.editor delete", help = "Delete a saved placement by key.", parameters = { { name = "key" } } },
        { command = "/remote-camera.editor snap", help = "Snap the edited display to the surface under your aim." },
        { command = "/remote-camera.editor close", help = "Close the editor and discard the draft." },
        { command = "/remote-camera.editor sync", help = "Force one reconcile pass over the saved placements." },
    })
end)
