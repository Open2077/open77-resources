-- Pure server-side authority for the open77_remote_camera provider.
--
-- Everything policy-shaped lives here: which cameras, screens, HUD views and
-- interest-only leases exist for which resource generation, who may watch them,
-- and what the host must do so reality matches -- hold one replication-interest
-- point per (camera, viewer) pair, bind one presentation on that viewer's
-- client, retire both. The adapter (server/main.lua) owns no rule of its own: it
-- hands this module a roster and executes the effects it is given, then reports
-- the interest results back.
--
-- No caller-supplied owner is ever trusted. The adapter passes the invoking
-- resource name and generation it read from the platform; every record is keyed
-- by that pair; a record whose generation is no longer live is removed by the
-- next pass, cascading to everything that depended on it.
RemoteCameraAuthority = {}

local MAX_CAMERAS = 1024
local MAX_CAMERAS_PER_RESOURCE = 64
local MAX_SCREENS = 512
local MAX_SCREENS_PER_RESOURCE = 64
local MAX_VIEWS = 1024
local MAX_VIEWS_PER_RESOURCE = 256
local MAX_LEASES = 1024
local MAX_LEASES_PER_RESOURCE = 256
local MAX_GRANTS_PER_CAMERA = 256
local MAX_RESOURCE_NAME = 64
local MAX_KEY_LENGTH = 64
local MAX_MODEL_LENGTH = 64
local MAX_COORDINATE = 1000000
local MAX_BUCKET = 1000000
local MAX_ID = 9007199254740991
local MAX_PLACEMENT_EXTENT = 40.0
local MAX_RECT_EXTENT = 16384
local DEFAULT_FOV = 60.0
local DEFAULT_RANGE = 100.0
local DEFAULT_SCREEN_RADIUS = 40.0
local DEFAULT_SCREEN_WIDTH = 2.4
local DEFAULT_SCREEN_HEIGHT = 1.35
-- A bind is a question, not a fact: the client answers once its native binding
-- is either established or refused. Nothing arrives within the timeout -- a
-- client that crashed, a session that stalled -- and the same presentation is
-- asked for again under a new attempt id. A refusal waits a little longer,
-- because the reason is usually a full slot table the player has to walk away
-- from or an operator has to widen.
local PRESENT_ACK_TIMEOUT_MS = 4000
local PRESENT_RETRY_MS = 2000

local DESCRIPTION_FIELDS = {
    key = true, position = true, rotation = true, fov = true,
    range = true, bucket = true, enabled = true, housing = true,
}
local PATCH_FIELDS = {
    position = true, rotation = true, fov = true, range = true,
    bucket = true, enabled = true, housing = true,
}
local GRANT_FIELDS = { view = true }
-- A camera's visible housing: a server-owned prop placed at the camera's pose so
-- every player in range sees a camera on the wall. `offset` and `yaw` are in the
-- camera's own frame -- +X right, +Y forward, +Z up -- because the authored prop
-- origin is rarely the lens.
local HOUSING_FIELDS = { model = true, offset = true, yaw = true }
local MAX_HOUSING_OFFSET = 10.0
-- A housing placed exactly at the pose films its own body: the mesh extends
-- forward from its origin. An omitted offset therefore means "behind the lens",
-- in the camera's own frame where +Y is forward, rather than zero. A caller who
-- really wants it at the pose passes `offset = { x = 0, y = 0, z = 0 }`.
local DEFAULT_HOUSING_OFFSET = { x = 0.0, y = -0.35, z = 0.0 }
local PLACEMENT_FIELDS = {
    position = true, rotation = true, width = true, height = true,
    radius = true, access = true, model = true, parent = true,
}
local SCREEN_PATCH_FIELDS = {
    cameraId = true, position = true, rotation = true, width = true, height = true,
    radius = true, access = true, model = true, parent = true,
}
local VIEW_PATCH_FIELDS = { cameraId = true, rect = true, visible = true, surface = true }
-- How a view is drawn on its viewer's client: a native HUD rectangle, or the
-- camera image behind a transparent resource-owned page.
local VIEW_SURFACES = { hud = true, webui = true }
local RECT_FIELDS = { x = true, y = true, width = true, height = true }
local ACCESS_VALUES = { public = true, granted = true }
-- The canonical parents a screen may ride: a replicated prop, a player or a
-- server-owned vehicle, named by the id the platform issued. Never a client
-- entity handle -- those are one machine's business.
local PARENT_TYPES = { prop = true, player = true, vehicle = true }
local PARENT_FIELDS = { type = true, id = true }

local function copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, item in next, value, nil do result[key] = copy(item) end
    return result
end

local function finite(value, limit)
    return type(value) == "number" and value == value and value ~= math.huge
        and value ~= -math.huge and math.abs(value) <= (limit or MAX_COORDINATE)
end

local function ranged(value, low, high)
    return finite(value, high) and value >= low and value <= high
end

local function integer(value, low, high)
    return ranged(value, low, high) and value % 1 == 0
end

-- A parent's frame can be a heading or a full orientation. The orientation is
-- applied as the ordinary q * v * q^-1; the quaternion is normalised here rather
-- than trusted, and a degenerate one (zero, or not finite) is refused so the
-- panel is not placed by a guess.
local function rotateOrientation(orientation, offset)
    local x, y, z, w = orientation.x, orientation.y, orientation.z, orientation.w
    if not (finite(x) and finite(y) and finite(z) and finite(w)) then return nil end
    local norm = math.sqrt(x * x + y * y + z * z + w * w)
    if norm <= 0 then return nil end
    x, y, z, w = x / norm, y / norm, z / norm, w / norm
    -- t = 2 * (q_xyz x v); v' = v + w * t + (q_xyz x t)
    local tx = 2 * (y * offset.z - z * offset.y)
    local ty = 2 * (z * offset.x - x * offset.z)
    local tz = 2 * (x * offset.y - y * offset.x)
    return {
        x = offset.x + w * tx + (y * tz - z * ty),
        y = offset.y + w * ty + (z * tx - x * tz),
        z = offset.z + w * tz + (x * ty - y * tx),
    }
end

local function validOwner(owner)
    return type(owner) == "string" and #owner > 0 and #owner <= MAX_RESOURCE_NAME
        and not owner:find("[%c]", 1)
end

local function validKey(key)
    return type(key) == "string" and #key > 0 and #key <= MAX_KEY_LENGTH
        and not key:find("[%c]", 1)
end

-- A screen model alias names a display profile the native side resolves; the
-- provider only guarantees it is a plain token (not a path, a mesh name or
-- anything else a placement could smuggle onto the wire).
local function validModel(model)
    return type(model) == "string" and #model > 0 and #model <= MAX_MODEL_LENGTH
        and model:match("^[%w_%-%.:]+$") ~= nil
end

local function validId(id)
    return integer(id, 1, MAX_ID)
end


local function exactFields(value, allowed)
    if type(value) ~= "table" then return false end
    for key in next, value, nil do
        if not allowed[key] then return false, key end
    end
    return true
end

-- A parent is either named ({ type, id }), absent (nil) or explicitly removed
-- (false). Anything else is refused by name rather than guessed at.
--
-- Prop ids are unsigned 64-bit decimals and `Open77.props.get` publishes them as
-- strings, because most of them do not fit a Lua number -- so they are validated
-- and carried as strings end to end and never converted through a float, which
-- would silently point a panel at a different prop. Player and vehicle ids are
-- numeric platform ids and stay numbers. Either way the id is used exactly as
-- given: this module never rewrites an identity.
local MAX_UNSIGNED64 = "18446744073709551615"

local function validPropId(id)
    if type(id) ~= "string" or #id == 0 or #id > #MAX_UNSIGNED64 or id:match("^%d+$") == nil then
        return false
    end
    -- Zero, and anything that is not the canonical spelling (leading zeros).
    if id:sub(1, 1) == "0" then return false end
    if #id == #MAX_UNSIGNED64 then return id <= MAX_UNSIGNED64 end
    return true
end

local function normalizeParent(value)
    if value == nil or value == false then return value end
    if type(value) ~= "table" then return nil, "invalid_parent" end
    local ok = exactFields(value, PARENT_FIELDS)
    if not ok then return nil, "invalid_parent" end
    local kind = rawget(value, "type")
    if not PARENT_TYPES[kind] then return nil, "invalid_parent" end
    local id = rawget(value, "id")
    if kind == "prop" then
        if not validPropId(id) then return nil, "invalid_parent" end
        return { type = kind, id = id }
    end
    if type(id) ~= "number" or not validId(id) then return nil, "invalid_parent" end
    return { type = kind, id = id }
end

local function vector(value, fields)
    if type(value) ~= "table" then return nil end
    for key in next, value, nil do
        local known = false
        for _, field in ipairs(fields) do
            if key == field then known = true break end
        end
        if not known then return nil end
    end
    local result = {}
    for _, field in ipairs(fields) do
        local number = rawget(value, field)
        if not finite(number) then return nil end
        result[field] = number
    end
    return result
end

local function same(a, b)
    if type(a) ~= type(b) then return false end
    if type(a) ~= "table" then return a == b end
    for key, value in next, a, nil do
        if not same(value, rawget(b, key)) then return false end
    end
    for key in next, b, nil do
        if rawget(a, key) == nil then return false end
    end
    return true
end

local function removeValue(list, value)
    for index = #list, 1, -1 do
        if list[index] == value then
            table.remove(list, index)
            return true
        end
    end
    return false
end

function RemoteCameraAuthority.new(api)
    api = type(api) == "table" and api or {}

    local S = {
        cameras = {},           -- id -> camera
        screens = {},           -- id -> screen
        views = {},             -- id -> view
        leases = {},            -- id -> lease
        byOwner = {},           -- owner -> { cameras = {}, screens = {}, views = {}, leases = {} }
        cameraIndex = {},       -- cameraId -> { screens = {}, views = {}, leases = {} }
        playerIndex = {},       -- player -> { screens = {}, views = {}, leases = {} }
        keys = {},              -- owner -> key -> cameraId
        interest = {},          -- player -> cameraId -> { state, point }
        dismissals = {},        -- queued client dismissals, drained by reconcile
        revision = 0,           -- monotone: record ids, attempt ids and payload revisions
        now = 0,                -- the clock the last reconcile ran against
        count = { cameras = 0, screens = 0, views = 0, leases = 0 },
    }

    ----------------------------------------------------------------------
    -- Platform facts
    ----------------------------------------------------------------------

    local function generationLive(owner, generation)
        if not validOwner(owner) or generation == nil or type(api.generation) ~= "function" then
            return false
        end
        local ok, current = pcall(api.generation, owner)
        return ok and current ~= nil and current == generation
    end

    local function checkOwner(owner, generation)
        if not validOwner(owner) or generation == nil then return false, "invalid_owner" end
        if not generationLive(owner, generation) then return false, "owner_stopped" end
        return true
    end

    local function readRoster()
        if type(api.roster) ~= "function" then return {} end
        local ok, roster = pcall(api.roster)
        if not ok or type(roster) ~= "table" then return {} end
        return roster
    end

    -- A parent is a canonical replicated object, so the server can ask for it.
    -- When it cannot -- not spawned, not streamed, a stale id -- there is no
    -- honest world pose for the panel, and everything that needs one says
    -- `parent_unavailable` instead of placing the panel at its local offset.
    local function resolveParent(parent)
        if type(api.parentPose) ~= "function" then return nil, "parent_unavailable" end
        local ok, pose = pcall(api.parentPose, parent)
        if not ok or type(pose) ~= "table" then return nil, "parent_unavailable" end
        return pose
    end

    -- Where a screen actually is: for a parented one, the parent's position plus
    -- the local offset in the parent's frame. A frame the platform reports as an
    -- orientation is used in full; a prop's authored root is a heading, and a
    -- parent whose frame cannot be established -- no orientation, no heading --
    -- has no honest world point at all, so the caller is told `parent_unavailable`
    -- rather than handed the offset as if it were the world. `bucket` is nil for a
    -- parentless screen: its bucket is the camera's, as it always was.
    local function screenPose(screen)
        local position = screen.placement.position
        local parent = screen.placement.parent
        if parent == nil then
            return { x = position.x, y = position.y, z = position.z, bucket = nil }
        end
        local pose, reason = resolveParent(parent)
        if not pose then return nil, reason end
        local offset
        if pose.orientation ~= nil then
            offset = rotateOrientation(pose.orientation, position)
            if not offset then return nil, "parent_unavailable" end
        elseif finite(pose.yaw) then
            local radians = math.rad(pose.yaw)
            local cos, sin = math.cos(radians), math.sin(radians)
            offset = {
                x = position.x * cos - position.y * sin,
                y = position.x * sin + position.y * cos,
                z = position.z,
            }
        else
            return nil, "parent_unavailable"
        end
        return { x = pose.x + offset.x, y = pose.y + offset.y, z = pose.z + offset.z,
            bucket = pose.bucket }
    end

    ----------------------------------------------------------------------
    -- Bookkeeping
    ----------------------------------------------------------------------

    local function nextSerial()
        S.revision = S.revision + 1
        return S.revision
    end

    local function touch(record)
        record.revision = nextSerial()
        return record.revision
    end

    local function emit(kind, action, record, fields)
        if type(api.event) ~= "function" then return end
        local event = {}
        if fields then
            for key, value in next, fields, nil do event[key] = value end
        end
        event.kind, event.action = kind, action
        event.owner, event.generation = record.owner, record.generation
        event.revision = record.revision
        api.event(event)
    end

    local function ownerSets(owner)
        local sets = S.byOwner[owner]
        if not sets then
            sets = { cameras = {}, screens = {}, views = {}, leases = {} }
            S.byOwner[owner] = sets
        end
        return sets
    end

    local function link(kind, record)
        local sets = ownerSets(record.owner)
        local list = sets[kind]
        list[#list + 1] = record.id
        S.count[kind] = S.count[kind] + 1
        -- A camera is the thing the others hang off; only screens, views and
        -- leases index back to one.
        if kind ~= "cameras" then
            local refs = S.cameraIndex[record.cameraId]
            if not refs then
                refs = { screens = {}, views = {}, leases = {} }
                S.cameraIndex[record.cameraId] = refs
            end
            refs[kind][#refs[kind] + 1] = record.id
            -- Only views and leases carry a player of their own; a screen's
            -- players are its viewers, linked where they are attached.
            if type(record.player) == "number" then
                local playerRefs = S.playerIndex[record.player]
                if not playerRefs then
                    playerRefs = { screens = {}, views = {}, leases = {} }
                    S.playerIndex[record.player] = playerRefs
                end
                playerRefs[kind][#playerRefs[kind] + 1] = record.id
            end
        end
    end

    local function unlink(kind, record)
        local sets = S.byOwner[record.owner]
        if sets then
            removeValue(sets[kind], record.id)
            if #sets.cameras == 0 and #sets.screens == 0 and #sets.views == 0 and #sets.leases == 0 then
                S.byOwner[record.owner] = nil
            end
        end
        S.count[kind] = S.count[kind] - 1
        if kind ~= "cameras" then
            local refs = S.cameraIndex[record.cameraId]
            if refs then
                removeValue(refs[kind], record.id)
                if #refs.screens == 0 and #refs.views == 0 and #refs.leases == 0 then
                    S.cameraIndex[record.cameraId] = nil
                end
            end
            if type(record.player) == "number" then
                local playerRefs = S.playerIndex[record.player]
                if playerRefs then
                    removeValue(playerRefs[kind], record.id)
                    if #playerRefs.screens == 0 and #playerRefs.views == 0 and #playerRefs.leases == 0 then
                        S.playerIndex[record.player] = nil
                    end
                end
            end
        end
    end

    -- A presentation that no longer exists still has to be taken off the client
    -- that was drawing it. The record is gone by the time the adapter runs, so
    -- the intent is queued here and drained into the next effect list.
    local function dismiss(player, id)
        S.dismissals[#S.dismissals + 1] = { player = player, id = id }
    end

    ----------------------------------------------------------------------
    -- Validation
    ----------------------------------------------------------------------

    local function normalizeRotation(value)
        if value == nil then return { yaw = 0, pitch = 0, roll = 0 } end
        return vector(value, { "yaw", "pitch", "roll" })
    end

    -- Absent, invalid or normalized -- in that order. `nil` means "no housing",
    -- `false, reason` means the caller asked for one and got it wrong, and a
    -- table is the normalized form. A model is not checked against the catalogue
    -- here: the catalogue belongs to the client that hosts the props, and the
    -- prop call answers `unknown_alias` when it is wrong.
    local function normalizeHousing(value)
        if value == nil then return nil end
        if type(value) ~= "table" then return false, "invalid_housing" end
        local ok, unknown = exactFields(value, HOUSING_FIELDS)
        if not ok then return false, "unknown_field:" .. tostring(unknown) end
        local model = rawget(value, "model")
        if not validModel(model) then return false, "invalid_housing_model" end
        local offset = rawget(value, "offset")
        if offset == nil then
            offset = copy(DEFAULT_HOUSING_OFFSET)
        else
            offset = vector(offset, { "x", "y", "z" })
            if not offset then return false, "invalid_housing_offset" end
            for _, axis in ipairs({ "x", "y", "z" }) do
                if not finite(offset[axis], MAX_HOUSING_OFFSET) then
                    return false, "invalid_housing_offset"
                end
            end
        end
        local yaw = rawget(value, "yaw")
        if yaw == nil then yaw = 0.0 end
        if not finite(yaw, 360.0) then return false, "invalid_housing_yaw" end
        return { model = model, offset = offset, yaw = yaw }
    end

    local function normalizeDescription(description)
        if type(description) ~= "table" then return nil, "invalid_description" end
        local ok, unknown = exactFields(description, DESCRIPTION_FIELDS)
        if not ok then return nil, "unknown_field:" .. tostring(unknown) end

        local key = rawget(description, "key")
        if not validKey(key) then return nil, "invalid_key" end
        local position = vector(rawget(description, "position"), { "x", "y", "z" })
        if not position then return nil, "invalid_position" end
        local rotation = normalizeRotation(rawget(description, "rotation"))
        if not rotation then return nil, "invalid_rotation" end
        local fov = rawget(description, "fov")
        if fov == nil then fov = DEFAULT_FOV end
        if not ranged(fov, 1, 120) then return nil, "invalid_fov" end
        local range = rawget(description, "range")
        if range == nil then range = DEFAULT_RANGE end
        if not ranged(range, 1, 500) then return nil, "invalid_range" end
        local bucket = rawget(description, "bucket")
        if not integer(bucket, 0, MAX_BUCKET) then return nil, "invalid_bucket" end
        local enabled = rawget(description, "enabled")
        if enabled == nil then enabled = true end
        if type(enabled) ~= "boolean" then return nil, "invalid_enabled" end
        local housing, housingReason = normalizeHousing(rawget(description, "housing"))
        if housing == false then return nil, housingReason end

        return {
            key = key, position = position, rotation = rotation, fov = fov,
            range = range, bucket = bucket, enabled = enabled, housing = housing,
        }
    end

    local function normalizePlacement(placement)
        if type(placement) ~= "table" then return nil, "invalid_placement" end
        local ok, unknown = exactFields(placement, PLACEMENT_FIELDS)
        if not ok then return nil, "unknown_field:" .. tostring(unknown) end
        local position = vector(rawget(placement, "position"), { "x", "y", "z" })
        if not position then return nil, "invalid_position" end
        local rotation = normalizeRotation(rawget(placement, "rotation"))
        if not rotation then return nil, "invalid_rotation" end
        local width = rawget(placement, "width")
        if width == nil then width = DEFAULT_SCREEN_WIDTH end
        if not ranged(width, 0.01, MAX_PLACEMENT_EXTENT) then return nil, "invalid_screen_size" end
        local height = rawget(placement, "height")
        if height == nil then height = DEFAULT_SCREEN_HEIGHT end
        if not ranged(height, 0.01, MAX_PLACEMENT_EXTENT) then return nil, "invalid_screen_size" end
        local radius = rawget(placement, "radius")
        if radius == nil then radius = DEFAULT_SCREEN_RADIUS end
        if not ranged(radius, 1.0, 500.0) then return nil, "invalid_screen_radius" end
        local access = rawget(placement, "access")
        if access == nil then access = "granted" end
        if not ACCESS_VALUES[access] then return nil, "invalid_screen_access" end
        local model = rawget(placement, "model")
        if model ~= nil and not validModel(model) then return nil, "invalid_screen_model" end
        local parent, parentReason = normalizeParent(rawget(placement, "parent"))
        if parent == false then parent = nil
        elseif parent == nil and rawget(placement, "parent") ~= nil then
            return nil, parentReason
        end
        return {
            position = position, rotation = rotation, width = width, height = height,
            radius = radius, access = access, model = model, parent = parent,
        }
    end

    -- `complete` asks for all four fields (opening a view); without it the rect
    -- is a sparse patch over `base`.
    local function normalizeRect(rect, base, complete)
        if type(rect) ~= "table" then return nil, "invalid_rect" end
        local ok, unknown = exactFields(rect, RECT_FIELDS)
        if not ok then return nil, "unknown_field:" .. tostring(unknown) end
        local merged = copy(base or {})
        for field in next, RECT_FIELDS, nil do
            local value = rawget(rect, field)
            if value == nil then
                if complete or merged[field] == nil then return nil, "invalid_rect" end
            elseif field == "width" or field == "height" then
                if not ranged(value, 1, MAX_RECT_EXTENT) then return nil, "invalid_rect" end
                merged[field] = value
            else
                if not finite(value) then return nil, "invalid_rect" end
                merged[field] = value
            end
        end
        return merged
    end

    ----------------------------------------------------------------------
    -- Ownership lookups
    ----------------------------------------------------------------------

    local function owned(store, owner, generation, id)
        local ok, reason = checkOwner(owner, generation)
        if not ok then return nil, reason end
        if not validId(id) then return nil, "invalid_id" end
        local record = store[id]
        if not record then return nil, "not_found" end
        if record.owner ~= owner or record.generation ~= generation then return nil, "not_owner" end
        return record
    end

    local function cameraFor(owner, generation, id)
        return owned(S.cameras, owner, generation, id)
    end

    local function hasGrant(camera, player)
        local grant = camera.grants[tostring(player)]
        return grant ~= nil and grant.view == true
    end

    local function ownerWithin(owner, kind, limit, globalLimit)
        local sets = S.byOwner[owner]
        if (sets and #sets[kind] or 0) >= limit then return false, "resource_limit" end
        if S.count[kind] >= globalLimit then return false, "registry_full" end
        return true
    end

    ----------------------------------------------------------------------
    -- Snapshots
    ----------------------------------------------------------------------

    local function cameraSnapshot(camera)
        return {
            id = camera.id, key = camera.key, owner = camera.owner,
            position = copy(camera.position), rotation = copy(camera.rotation),
            fov = camera.fov, range = camera.range, bucket = camera.bucket,
            enabled = camera.enabled, grants = camera.grantCount, revision = camera.revision,
            -- The housing is reported with the prop it actually produced, so a
            -- caller can tell "asked for" from "on the wall".
            housing = camera.housing and {
                model = camera.housing.model, offset = copy(camera.housing.offset),
                yaw = camera.housing.yaw, propId = camera.propId,
                reason = camera.housingReason,
            } or nil,
        }
    end

    local function screenSnapshot(screen)
        local viewers = {}
        for player, viewer in next, screen.viewers, nil do
            viewers[#viewers + 1] = { playerId = player, state = viewer.state, reason = viewer.reason }
        end
        table.sort(viewers, function(a, b) return a.playerId < b.playerId end)
        return {
            id = screen.id, owner = screen.owner, cameraId = screen.cameraId,
            placement = copy(screen.placement), viewers = viewers, revision = screen.revision,
        }
    end

    local function viewSnapshot(view)
        return {
            id = view.id, owner = view.owner, playerId = view.player, cameraId = view.cameraId,
            rect = copy(view.rect), visible = view.visible, surface = view.surface, state = view.state,
            reason = view.reason, revision = view.revision,
        }
    end

    local function leaseSnapshot(lease)
        local camera = S.cameras[lease.cameraId]
        return {
            id = lease.id, owner = lease.owner, playerId = lease.player, cameraId = lease.cameraId,
            camera = camera and cameraSnapshot(camera) or nil,
        }
    end

    ----------------------------------------------------------------------
    -- Lifecycle (forward declared: removals cascade)
    ----------------------------------------------------------------------

    local removeCamera, removeScreen, revokeView, releaseLease, detachViewer, attachViewer

    local function releaseLease_(lease, reason)
        if S.leases[lease.id] ~= lease then return false end
        S.leases[lease.id] = nil
        unlink("leases", lease)
        emit("lease", "released", lease,
            { leaseId = lease.id, cameraId = lease.cameraId, playerId = lease.player, reason = reason })
        return true
    end
    releaseLease = releaseLease_

    local function revokeView_(view, reason)
        if S.views[view.id] ~= view then return false end
        S.views[view.id] = nil
        unlink("views", view)
        dismiss(view.player, view.id)
        emit("view", "closed", view,
            { viewId = view.id, cameraId = view.cameraId, playerId = view.player,
              state = "closed", reason = reason })
        return true
    end
    revokeView = revokeView_

    local function detachViewer_(screen, player, reason)
        if screen.viewers[player] == nil then return false end
        screen.viewers[player] = nil
        dismiss(player, screen.id)
        local refs = S.playerIndex[player]
        if refs then removeValue(refs.screens, screen.id) end
        emit("screenViewer", "detached", screen,
            { screenId = screen.id, cameraId = screen.cameraId, playerId = player,
              state = "closed", reason = reason })
        return true
    end
    detachViewer = detachViewer_

    local function attachViewer_(screen, player)
        screen.viewers[player] = {
            player = player, state = "pending", reason = nil, attempt = nil,
            sentRevision = nil, nextAttemptAt = 0,
        }
        local refs = S.playerIndex[player]
        if not refs then
            refs = { screens = {}, views = {}, leases = {} }
            S.playerIndex[player] = refs
        end
        refs.screens[#refs.screens + 1] = screen.id
        emit("screenViewer", "attached", screen,
            { screenId = screen.id, cameraId = screen.cameraId, playerId = player, state = "pending" })
    end
    attachViewer = attachViewer_

    local function removeScreen_(screen, reason)
        if S.screens[screen.id] ~= screen then return false end
        for player in next, copy(screen.viewers), nil do
            screen.viewers[player] = nil
            dismiss(player, screen.id)
            local refs = S.playerIndex[player]
            if refs then removeValue(refs.screens, screen.id) end
        end
        S.screens[screen.id] = nil
        unlink("screens", screen)
        emit("screen", "removed", screen,
            { screenId = screen.id, cameraId = screen.cameraId, reason = reason })
        return true
    end
    removeScreen = removeScreen_

    -- The housing prop is server-owned, which is what makes it visible to
    -- everyone in range rather than to one client. It follows the camera record:
    -- created with it, moved when its pose or offset changes, removed with it.
    -- The prop's own authored origin is rarely the lens, so the offset and yaw
    -- are expressed in the camera's frame (+X right, +Y forward, +Z up) and
    -- resolved here; none of that arithmetic reaches the caller.
    local function housingPose(camera)
        local housing = camera.housing
        local yaw = math.rad(camera.rotation.yaw)
        local right = { x = math.cos(yaw), y = math.sin(yaw) }
        local forward = { x = -math.sin(yaw), y = math.cos(yaw) }
        local offset = housing.offset
        return {
            x = camera.position.x + right.x * offset.x + forward.x * offset.y,
            y = camera.position.y + right.y * offset.x + forward.y * offset.y,
            z = camera.position.z + offset.z,
        }, camera.rotation.yaw + housing.yaw
    end

    local function removeHousing(camera)
        if not camera.propId then return end
        local props = Open77 and Open77.props
        if props then props.remove(camera.propId) end
        camera.propId, camera.housingReason = nil, nil
    end

    local function syncHousing(camera)
        if not camera.housing then
            removeHousing(camera)
            return
        end
        local props = Open77 and Open77.props
        if not props then
            camera.housingReason = "props_unavailable"
            return
        end
        local position, yaw = housingPose(camera)
        if camera.propId then
            local ok, reason = props.setTransform(camera.propId, { position = position, yaw = yaw })
            camera.housingReason = ok and nil or tostring(reason)
            if not ok then
                -- A prop that no longer exists cannot be moved back into place;
                -- drop the id so the next sync creates a fresh one.
                camera.propId = nil
            end
            return
        end
        local id, reason = props.create({
            model = camera.housing.model, position = position, yaw = yaw,
        })
        if not id then
            camera.housingReason = tostring(reason)
            return
        end
        camera.propId, camera.housingReason = id, nil
        if camera.bucket ~= 0 then props.setBucket(id, camera.bucket) end
    end

    local function removeCamera_(camera, reason)
        if S.cameras[camera.id] ~= camera then return false end
        local refs = S.cameraIndex[camera.id]
        if refs then
            for _, screenId in ipairs(copy(refs.screens)) do
                local screen = S.screens[screenId]
                if screen then removeScreen(screen, reason) end
            end
            for _, viewId in ipairs(copy(refs.views)) do
                local view = S.views[viewId]
                if view then revokeView(view, reason) end
            end
            for _, leaseId in ipairs(copy(refs.leases)) do
                local lease = S.leases[leaseId]
                if lease then releaseLease(lease, reason) end
            end
        end
        S.cameras[camera.id] = nil
        unlink("cameras", camera)
        removeHousing(camera)
        local ownerKeys = S.keys[camera.owner]
        if ownerKeys then
            if ownerKeys[camera.key] == camera.id then ownerKeys[camera.key] = nil end
            if next(ownerKeys) == nil then S.keys[camera.owner] = nil end
        end
        emit("camera", "removed", camera, { cameraId = camera.id, reason = reason })
        return true
    end
    removeCamera = removeCamera_

    ----------------------------------------------------------------------
    -- Interest bookkeeping
    ----------------------------------------------------------------------

    local function interestEntry(player, cameraId)
        local per = S.interest[player]
        return per and per[cameraId] or nil
    end

    local function setInterest(player, cameraId, state, point)
        local per = S.interest[player]
        if state == nil then
            if per then
                per[cameraId] = nil
                if next(per) == nil then S.interest[player] = nil end
            end
            return
        end
        if not per then
            per = {}
            S.interest[player] = per
        end
        per[cameraId] = { state = state, point = point }
    end

    -- A refused interest point is not a panel that failed: it is a world that is
    -- not being replicated to a viewer. Every presentation on the pair is put
    -- into `unavailable` -- record kept, nothing drawn -- and retried, while an
    -- interest-only lease has no meaning without its point at all and ends.
    local function interestFailed(player, cameraId, reason)
        local refs = S.cameraIndex[cameraId]
        if not refs then return end
        for _, screenId in ipairs(copy(refs.screens)) do
            local screen = S.screens[screenId]
            local viewer = screen and screen.viewers[player]
            if viewer and viewer.state ~= "unavailable" then
                viewer.state, viewer.reason = "unavailable", reason
                viewer.attempt, viewer.sentRevision, viewer.nextAttemptAt = nil, nil, 0
                dismiss(player, screenId)
                emit("screenViewer", "state", screen,
                    { screenId = screenId, cameraId = cameraId, playerId = player,
                      state = "unavailable", reason = reason })
            end
        end
        for _, viewId in ipairs(copy(refs.views)) do
            local view = S.views[viewId]
            if view and view.player == player and view.state ~= "unavailable" then
                view.state, view.reason = "unavailable", reason
                view.attempt, view.sentRevision, view.nextAttemptAt = nil, nil, 0
                dismiss(player, viewId)
                emit("view", "state", view,
                    { viewId = viewId, cameraId = cameraId, playerId = player,
                      state = "unavailable", reason = reason })
            end
        end
        for _, leaseId in ipairs(copy(refs.leases)) do
            local lease = S.leases[leaseId]
            if lease and lease.player == player then releaseLease(lease, reason) end
        end
    end

    ----------------------------------------------------------------------
    -- Liveness
    ----------------------------------------------------------------------

    -- Everything hangs off a camera owned by one resource generation, so a dead
    -- owner is one pass over the cameras: screens, views and leases go with the
    -- camera they name.
    function S.tick()
        local stale = {}
        for _, camera in next, S.cameras, nil do
            if not generationLive(camera.owner, camera.generation) then
                stale[#stale + 1] = camera
            end
        end
        for _, camera in ipairs(stale) do removeCamera(camera, "owner_stopped") end
        return #stale
    end

    -- A resource that has just restarted is a new generation, and its previous
    -- records are dead even before the sweep runs. Dropping them here means a
    -- restart is not counted against its own limits by the calls it makes in the
    -- first quarter second -- the moment a resource re-creates its cameras is
    -- exactly when its stale ones are still on the books.
    local function reapOwner(owner, generation)
        local sets = S.byOwner[owner]
        if not sets or #sets.cameras == 0 then return end
        for _, id in ipairs(copy(sets.cameras)) do
            local camera = S.cameras[id]
            if camera and camera.generation ~= generation then
                removeCamera(camera, "owner_stopped")
            end
        end
    end

    ----------------------------------------------------------------------
    -- Cameras
    ----------------------------------------------------------------------

    function S.create(owner, generation, description)
        local ok, reason = checkOwner(owner, generation)
        if not ok then return nil, reason end
        reapOwner(owner, generation)
        local normalized
        normalized, reason = normalizeDescription(description)
        if not normalized then return nil, reason end
        if S.count.cameras >= MAX_CAMERAS then return nil, "registry_full" end
        if (S.byOwner[owner] and #S.byOwner[owner].cameras or 0) >= MAX_CAMERAS_PER_RESOURCE then
            return nil, "resource_limit"
        end
        local ownerKeys = S.keys[owner]
        if ownerKeys and ownerKeys[normalized.key] then return nil, "duplicate_key" end
        if S.revision >= MAX_ID then return nil, "registry_full" end

        local camera = {
            id = nextSerial(),
            key = normalized.key,
            owner = owner,
            generation = generation,
            position = normalized.position,
            rotation = normalized.rotation,
            fov = normalized.fov,
            range = normalized.range,
            bucket = normalized.bucket,
            enabled = normalized.enabled,
            housing = normalized.housing,
            propId = nil,
            housingReason = nil,
            grants = {},
            grantCount = 0,
            revision = 0,
        }
        S.cameras[camera.id] = camera
        link("cameras", camera)
        ownerKeys = S.keys[owner]
        if not ownerKeys then
            ownerKeys = {}
            S.keys[owner] = ownerKeys
        end
        ownerKeys[camera.key] = camera.id
        touch(camera)
        syncHousing(camera)
        emit("camera", "created", camera, { cameraId = camera.id, key = camera.key })
        return cameraSnapshot(camera)
    end

    function S.configure(owner, generation, id, patch)
        local camera, reason = cameraFor(owner, generation, id)
        if not camera then return false, reason end
        if type(patch) ~= "table" then return false, "invalid_patch" end
        local ok, unknown = exactFields(patch, PATCH_FIELDS)
        if not ok then return false, "unknown_field:" .. tostring(unknown) end

        local normalized = {}
        -- A patch cannot carry an absent key, so removal is an explicit
        -- sentinel: `housing = false` takes the housing off the wall, and a
        -- missing `housing` key means "not mentioned".
        local housingRemoved = rawget(patch, "housing") == false
        for field in next, patch, nil do
            local value = rawget(patch, field)
            if field == "position" then
                value = vector(value, { "x", "y", "z" })
                if not value then return false, "invalid_position" end
            elseif field == "rotation" then
                value = vector(value, { "yaw", "pitch", "roll" })
                if not value then return false, "invalid_rotation" end
            elseif field == "fov" then
                if not ranged(value, 1, 120) then return false, "invalid_fov" end
            elseif field == "range" then
                if not ranged(value, 1, 500) then return false, "invalid_range" end
            elseif field == "bucket" then
                if not integer(value, 0, MAX_BUCKET) then return false, "invalid_bucket" end
            elseif field == "enabled" then
                if type(value) ~= "boolean" then return false, "invalid_enabled" end
            elseif field == "housing" then
                if value == false then
                    value = nil
                else
                    value = normalizeHousing(value)
                    if value == false then return false, "invalid_housing" end
                end
            end
            normalized[field] = value
        end

        local changed = false
        for field, value in next, normalized, nil do
            if not same(camera[field], value) then
                camera[field] = value
                changed = true
            end
        end
        if housingRemoved and camera.housing ~= nil then
            camera.housing = nil
            changed = true
        end
        if not changed then return true end
        touch(camera)
        syncHousing(camera)
        emit("camera", "configured", camera, { cameraId = camera.id })
        return true
    end

    function S.get(owner, generation, id)
        local camera, reason = cameraFor(owner, generation, id)
        if not camera then return nil, reason end
        return cameraSnapshot(camera)
    end

    function S.list(owner, generation)
        local ok, reason = checkOwner(owner, generation)
        if not ok then return nil, reason end
        local sets = S.byOwner[owner]
        local cameras = {}
        if sets then
            for _, id in ipairs(sets.cameras) do
                local camera = S.cameras[id]
                if camera and camera.generation == generation then
                    cameras[#cameras + 1] = cameraSnapshot(camera)
                end
            end
        end
        table.sort(cameras, function(a, b) return a.id < b.id end)
        return cameras
    end

    function S.remove(owner, generation, id)
        local camera, reason = cameraFor(owner, generation, id)
        if not camera then return false, reason end
        removeCamera(camera, "resource_removed")
        return true
    end

    ----------------------------------------------------------------------
    -- Explicit grants
    ----------------------------------------------------------------------

    function S.setAccess(owner, generation, id, player, actions)
        local camera, reason = cameraFor(owner, generation, id)
        if not camera then return false, reason end
        if not validId(player) then return false, "invalid_player" end
        if type(actions) ~= "table" then return false, "invalid_grant" end
        local ok, unknown = exactFields(actions, GRANT_FIELDS)
        if not ok then return false, "unknown_grant:" .. tostring(unknown) end
        local view = rawget(actions, "view")
        if type(view) ~= "boolean" then return false, "invalid_grant" end

        local key = tostring(player)
        local previous = camera.grants[key]
        if view == false then
            if previous == nil then return true end
            camera.grants[key] = nil
            camera.grantCount = camera.grantCount - 1
            touch(camera)
            emit("access", "revoked", camera, { cameraId = camera.id, playerId = player })
            -- A private presentation is authorized by this grant and nothing
            -- else, so losing it ends the views and leases that were riding on
            -- it. Public screen proximity is a separate admission and is not
            -- touched here: removing a grant must not take a street panel away
            -- from someone standing in front of it.
            local refs = S.cameraIndex[camera.id]
            if refs then
                for _, viewId in ipairs(copy(refs.views)) do
                    local current = S.views[viewId]
                    if current and current.player == player then revokeView(current, "access_revoked") end
                end
                for _, leaseId in ipairs(copy(refs.leases)) do
                    local lease = S.leases[leaseId]
                    if lease and lease.player == player then releaseLease(lease, "access_revoked") end
                end
            end
            return true
        end

        if previous ~= nil then return true end
        if camera.grantCount >= MAX_GRANTS_PER_CAMERA then return false, "grant_limit" end
        camera.grants[key] = { view = true }
        camera.grantCount = camera.grantCount + 1
        touch(camera)
        emit("access", "granted", camera, { cameraId = camera.id, playerId = player })
        return true
    end

    ----------------------------------------------------------------------
    -- Interest-only leases
    ----------------------------------------------------------------------

    function S.acquire(owner, generation, player, id)
        local ok, reason = checkOwner(owner, generation)
        if not ok then return nil, reason end
        reapOwner(owner, generation)
        if not validId(player) then return nil, "invalid_player" end
        local camera
        camera, reason = cameraFor(owner, generation, id)
        if not camera then return nil, reason end
        if not camera.enabled then return nil, "disabled" end
        ok, reason = ownerWithin(owner, "leases", MAX_LEASES_PER_RESOURCE, MAX_LEASES)
        if not ok then return nil, reason end
        local entry = readRoster()[player]
        if not entry then return nil, "player_unavailable" end
        if entry.ready ~= true then return nil, "player_not_ready" end
        if entry.bucket ~= camera.bucket then return nil, "wrong_bucket" end
        if not hasGrant(camera, player) then return nil, "access_denied" end

        local lease = {
            id = nextSerial(), owner = owner, generation = generation,
            player = player, cameraId = camera.id, revision = 0,
        }
        S.leases[lease.id] = lease
        link("leases", lease)
        touch(lease)
        emit("lease", "acquired", lease,
            { leaseId = lease.id, cameraId = camera.id, playerId = player })
        return leaseSnapshot(lease)
    end

    function S.release(owner, generation, id)
        local lease, reason = owned(S.leases, owner, generation, id)
        if not lease then return false, reason end
        releaseLease(lease, "released")
        return true
    end

    ----------------------------------------------------------------------
    -- Screens
    ----------------------------------------------------------------------

    function S.createScreen(owner, generation, cameraId, placement)
        local ok, reason = checkOwner(owner, generation)
        if not ok then return nil, reason end
        reapOwner(owner, generation)
        local camera
        camera, reason = cameraFor(owner, generation, cameraId)
        if not camera then return nil, reason end
        local normalized
        normalized, reason = normalizePlacement(placement)
        if not normalized then return nil, reason end
        ok, reason = ownerWithin(owner, "screens", MAX_SCREENS_PER_RESOURCE, MAX_SCREENS)
        if not ok then return nil, reason end
        if normalized.parent then
            -- An unresolvable parent is accepted: a screen may be authored
            -- before its prop exists, and the presentations say
            -- `parent_unavailable` until it does. A parent that IS there and
            -- lives in another bucket is a wrong pairing, refused by name.
            local pose = resolveParent(normalized.parent)
            if pose and pose.bucket ~= nil and pose.bucket ~= camera.bucket then
                return nil, "parent_bucket_mismatch"
            end
        end
        if S.revision >= MAX_ID then return nil, "registry_full" end

        local screen = {
            id = nextSerial(), owner = owner, generation = generation,
            cameraId = camera.id, placement = normalized, viewers = {}, revision = 0,
        }
        S.screens[screen.id] = screen
        link("screens", screen)
        touch(screen)
        emit("screen", "created", screen, { screenId = screen.id, cameraId = camera.id })
        return screen.id
    end

    function S.updateScreen(owner, generation, id, patch)
        local screen, reason = owned(S.screens, owner, generation, id)
        if not screen then return false, reason end
        if type(patch) ~= "table" then return false, "invalid_patch" end
        local ok, unknown = exactFields(patch, SCREEN_PATCH_FIELDS)
        if not ok then return false, "unknown_field:" .. tostring(unknown) end

        local cameraId = rawget(patch, "cameraId")
        local targetCamera
        if cameraId ~= nil then
            cameraId = tonumber(cameraId)
            targetCamera, reason = cameraFor(owner, generation, cameraId)
            if not targetCamera then return false, reason end
        end

        local placement = copy(screen.placement)
        if rawget(patch, "position") ~= nil then
            placement.position = vector(rawget(patch, "position"), { "x", "y", "z" })
            if not placement.position then return false, "invalid_position" end
        end
        if rawget(patch, "rotation") ~= nil then
            placement.rotation = normalizeRotation(rawget(patch, "rotation"))
            if not placement.rotation then return false, "invalid_rotation" end
        end
        if rawget(patch, "width") ~= nil then
            if not ranged(rawget(patch, "width"), 0.01, MAX_PLACEMENT_EXTENT) then
                return false, "invalid_screen_size"
            end
            placement.width = rawget(patch, "width")
        end
        if rawget(patch, "height") ~= nil then
            if not ranged(rawget(patch, "height"), 0.01, MAX_PLACEMENT_EXTENT) then
                return false, "invalid_screen_size"
            end
            placement.height = rawget(patch, "height")
        end
        if rawget(patch, "radius") ~= nil then
            if not ranged(rawget(patch, "radius"), 1.0, 500.0) then
                return false, "invalid_screen_radius"
            end
            placement.radius = rawget(patch, "radius")
        end
        if rawget(patch, "access") ~= nil then
            if not ACCESS_VALUES[rawget(patch, "access")] then return false, "invalid_screen_access" end
            placement.access = rawget(patch, "access")
        end
        if rawget(patch, "model") ~= nil then
            if not validModel(rawget(patch, "model")) then return false, "invalid_screen_model" end
            placement.model = rawget(patch, "model")
        end
        if rawget(patch, "parent") ~= nil then
            local raw = rawget(patch, "parent")
            local parent, parentReason = normalizeParent(raw)
            if parent == false then parent = nil
            elseif parent == nil then return false, parentReason end
            local previous = screen.placement.parent
            local moved = (parent == nil) ~= (previous == nil)
                or (parent ~= nil and previous ~= nil
                    and (parent.type ~= previous.type or parent.id ~= previous.id))
            if moved and (rawget(patch, "position") == nil or rawget(patch, "rotation") == nil) then
                -- Attaching and detaching re-express the pose: the same numbers
                -- mean a local offset in one frame and a world point in the
                -- other, so an omitted pose would silently move the panel.
                return false, "parent_pose_required"
            end
            placement.parent = parent
        end
        if placement.parent then
            local effective = targetCamera or S.cameras[screen.cameraId]
            local pose = resolveParent(placement.parent)
            if pose and pose.bucket ~= nil and pose.bucket ~= effective.bucket then
                return false, "parent_bucket_mismatch"
            end
        end

        local changed = false
        if targetCamera and targetCamera.id ~= screen.cameraId then
            local refs = S.cameraIndex[screen.cameraId]
            if refs then removeValue(refs.screens, screen.id) end
            screen.cameraId = targetCamera.id
            local target = S.cameraIndex[screen.cameraId]
            if not target then
                target = { screens = {}, views = {}, leases = {} }
                S.cameraIndex[screen.cameraId] = target
            end
            target.screens[#target.screens + 1] = screen.id
            -- The audience is re-decided against the new camera by the next
            -- pass; a viewer granted by the old camera is not carried over.
            for player in next, copy(screen.viewers), nil do
                screen.viewers[player] = nil
                dismiss(player, screen.id)
                local playerRefs = S.playerIndex[player]
                if playerRefs then removeValue(playerRefs.screens, screen.id) end
            end
            changed = true
        end
        if not same(screen.placement, placement) then
            screen.placement = placement
            changed = true
        end
        if not changed then return true end
        touch(screen)
        emit("screen", "configured", screen, { screenId = screen.id, cameraId = screen.cameraId })
        return true
    end

    function S.getScreen(owner, generation, id)
        local screen, reason = owned(S.screens, owner, generation, id)
        if not screen then return nil, reason end
        return screenSnapshot(screen)
    end

    function S.listScreens(owner, generation, cameraId)
        local ok, reason = checkOwner(owner, generation)
        if not ok then return nil, reason end
        local filter
        if cameraId ~= nil then
            filter = tonumber(cameraId)
            local camera
            camera, reason = cameraFor(owner, generation, filter)
            if not camera then return nil, reason end
            filter = camera.id
        end
        local sets = S.byOwner[owner]
        local screens = {}
        if sets then
            for _, id in ipairs(sets.screens) do
                local screen = S.screens[id]
                if screen and screen.generation == generation
                    and (filter == nil or screen.cameraId == filter) then
                    screens[#screens + 1] = screenSnapshot(screen)
                end
            end
        end
        table.sort(screens, function(a, b) return a.id < b.id end)
        return screens
    end

    function S.removeScreen(owner, generation, id)
        local screen, reason = owned(S.screens, owner, generation, id)
        if not screen then return false, reason end
        removeScreen(screen, "removed")
        return true
    end

    ----------------------------------------------------------------------
    -- HUD views
    ----------------------------------------------------------------------

    -- A HUD view is authorized exactly like a lease: ready, in the camera's
    -- bucket, and holding an explicit grant. A public screen's proximity
    -- admission never reaches this path.
    local function admitsViewer(camera, player, entry)
        if not entry then return nil, "player_unavailable" end
        if entry.ready ~= true then return nil, "player_not_ready" end
        if entry.bucket ~= camera.bucket then return nil, "wrong_bucket" end
        if not hasGrant(camera, player) then return nil, "access_denied" end
        return true
    end

    function S.openView(owner, generation, player, id, rect, surface)
        local ok, reason = checkOwner(owner, generation)
        if not ok then return nil, reason end
        reapOwner(owner, generation)
        if not validId(player) then return nil, "invalid_player" end
        if surface == nil then surface = "hud" end
        if not VIEW_SURFACES[surface] then return nil, "invalid_view_surface" end
        local camera
        camera, reason = cameraFor(owner, generation, id)
        if not camera then return nil, reason end
        if not camera.enabled then return nil, "disabled" end
        local normalized
        normalized, reason = normalizeRect(rect, nil, true)
        if not normalized then return nil, reason end
        ok, reason = ownerWithin(owner, "views", MAX_VIEWS_PER_RESOURCE, MAX_VIEWS)
        if not ok then return nil, reason end
        ok, reason = admitsViewer(camera, player, readRoster()[player])
        if not ok then return nil, reason end
        if S.revision >= MAX_ID then return nil, "registry_full" end

        local view = {
            id = nextSerial(), owner = owner, generation = generation, player = player,
            cameraId = camera.id, rect = normalized, visible = true, surface = surface,
            state = "pending", reason = nil, attempt = nil,
            sentRevision = nil, nextAttemptAt = 0, revision = 0,
        }
        S.views[view.id] = view
        link("views", view)
        touch(view)
        emit("view", "opened", view,
            { viewId = view.id, cameraId = camera.id, playerId = player, state = "pending" })
        return view.id
    end

    function S.updateView(owner, generation, id, patch)
        local view, reason = owned(S.views, owner, generation, id)
        if not view then return false, reason end
        if type(patch) ~= "table" then return false, "invalid_patch" end
        local ok, unknown = exactFields(patch, VIEW_PATCH_FIELDS)
        if not ok then return false, "unknown_field:" .. tostring(unknown) end

        local cameraId = rawget(patch, "cameraId")
        local targetCamera
        if cameraId ~= nil then
            cameraId = tonumber(cameraId)
            targetCamera, reason = cameraFor(owner, generation, cameraId)
            if not targetCamera then return false, reason end
            if not targetCamera.enabled then return false, "disabled" end
            -- A view is authorized against one camera, so the new one is asked
            -- the same questions before the picture is moved to it.
            ok, reason = admitsViewer(targetCamera, view.player, readRoster()[view.player])
            if not ok then return false, reason end
        end

        local rect = view.rect
        if rawget(patch, "rect") ~= nil then
            rect, reason = normalizeRect(rawget(patch, "rect"), view.rect, false)
            if not rect then return false, reason end
        end
        local visible = rawget(patch, "visible")
        if visible ~= nil and type(visible) ~= "boolean" then return false, "invalid_visible" end
        local surface = rawget(patch, "surface")
        if surface ~= nil and not VIEW_SURFACES[surface] then return false, "invalid_view_surface" end

        local changed = false
        if targetCamera and targetCamera.id ~= view.cameraId then
            local refs = S.cameraIndex[view.cameraId]
            if refs then removeValue(refs.views, view.id) end
            view.cameraId = targetCamera.id
            local target = S.cameraIndex[view.cameraId]
            if not target then
                target = { screens = {}, views = {}, leases = {} }
                S.cameraIndex[view.cameraId] = target
            end
            target.views[#target.views + 1] = view.id
            changed = true
        end
        if not same(view.rect, rect) then
            view.rect = rect
            changed = true
        end
        if visible ~= nil and view.visible ~= visible then
            view.visible = visible
            changed = true
        end
        if surface ~= nil and view.surface ~= surface then
            view.surface = surface
            changed = true
        end
        if not changed then return true end
        touch(view)
        emit("view", "configured", view,
            { viewId = view.id, cameraId = view.cameraId, playerId = view.player })
        return true
    end

    function S.getView(owner, generation, id)
        local view, reason = owned(S.views, owner, generation, id)
        if not view then return nil, reason end
        return viewSnapshot(view)
    end

    function S.listViews(owner, generation, player)
        local ok, reason = checkOwner(owner, generation)
        if not ok then return nil, reason end
        local filter
        if player ~= nil then
            filter = tonumber(player)
            if not validId(filter) then return nil, "invalid_player" end
        end
        local sets = S.byOwner[owner]
        local views = {}
        if sets then
            for _, id in ipairs(sets.views) do
                local view = S.views[id]
                if view and view.generation == generation
                    and (filter == nil or view.player == filter) then
                    views[#views + 1] = viewSnapshot(view)
                end
            end
        end
        table.sort(views, function(a, b) return a.id < b.id end)
        return views
    end

    function S.closeView(owner, generation, id)
        local view, reason = owned(S.views, owner, generation, id)
        if not view then return false, reason end
        revokeView(view, "closed")
        return true
    end

    ----------------------------------------------------------------------
    -- Lifecycle events from the platform
    ----------------------------------------------------------------------

    function S.dropPlayer(player, reason)
        player = tonumber(player)
        if not validId(player) then return 0 end
        local dropped = 0
        local refs = S.playerIndex[player]
        if refs then
            for _, viewId in ipairs(copy(refs.views)) do
                local view = S.views[viewId]
                if view then
                    revokeView(view, reason)
                    dropped = dropped + 1
                end
            end
            for _, leaseId in ipairs(copy(refs.leases)) do
                local lease = S.leases[leaseId]
                if lease then
                    releaseLease(lease, reason)
                    dropped = dropped + 1
                end
            end
            for _, screenId in ipairs(copy(refs.screens)) do
                local screen = S.screens[screenId]
                if screen and detachViewer(screen, player, reason) then dropped = dropped + 1 end
            end
        end
        -- Interest points are left for the next pass to diff away: the roster no
        -- longer names this player, so every pair they held is a removal.
        return dropped
    end

    -- A client resource that reloaded lost every native object it was drawing
    -- and cannot name them afterwards. The records stay -- the caller still owns
    -- them -- but every presentation on that client is asked for again from
    -- scratch, which is what brings the panels back. The interest points are
    -- left alone: the world around the camera is still replicated to them.
    function S.forgetPlayer(player)
        player = tonumber(player)
        if not validId(player) then return 0 end
        local forgotten = 0
        local refs = S.playerIndex[player]
        if refs then
            for _, viewId in ipairs(copy(refs.views)) do
                local view = S.views[viewId]
                if view then
                    view.state, view.reason, view.attempt = "pending", nil, nil
                    view.sentRevision, view.nextAttemptAt = nil, 0
                    forgotten = forgotten + 1
                end
            end
            for _, screenId in ipairs(copy(refs.screens)) do
                local screen = S.screens[screenId]
                local viewer = screen and screen.viewers[player]
                if viewer then
                    viewer.state, viewer.reason, viewer.attempt = "pending", nil, nil
                    viewer.sentRevision, viewer.nextAttemptAt = nil, 0
                    forgotten = forgotten + 1
                end
            end
        end
        return forgotten
    end

    -- One presentation, dropped by its own client after it had been established.
    -- The record is asked for again -- not created, moved or authorized, which is
    -- all this can ever do -- so a native binding that died between two sparse
    -- updates does not leave the server believing a panel is on screen forever.
    function S.presentationLost(player, id)
        if not validId(id) or not validId(player) then return false, "invalid_id" end
        local view = S.views[id]
        local record
        if view and view.player == player then
            record = view
        else
            local screen = S.screens[id]
            record = screen and screen.viewers[player] or nil
        end
        if not record then return false, "not_found" end
        record.state, record.reason, record.attempt = "pending", nil, nil
        record.sentRevision, record.nextAttemptAt = nil, 0
        return true
    end

    ----------------------------------------------------------------------
    -- Reconciliation
    ----------------------------------------------------------------------

    local function screenAdmission(screen, camera, player, entry, pose)
        -- nil, reason            -> this viewer must go
        -- "unavailable", reason  -> keep the record, stream and draw nothing
        if not entry or entry.ready ~= true then return nil, "player_not_ready" end
        if not pose then return "unavailable", "parent_unavailable" end
        if entry.bucket ~= camera.bucket then return nil, "wrong_bucket" end
        -- A panel rides its parent: when the parent has moved to another bucket,
        -- the panel went with it, whatever bucket the camera is still in.
        if pose.bucket ~= nil and entry.bucket ~= pose.bucket then return nil, "wrong_bucket" end
        local radius = screen.placement.radius
        local dx, dy, dz = entry.x - pose.x, entry.y - pose.y, entry.z - pose.z
        if dx * dx + dy * dy + dz * dz > radius * radius then return nil, "out_of_range" end
        if not camera.enabled then return "unavailable", "disabled" end
        -- Public proximity is decided here and nowhere else: it is this viewer
        -- record, not an entry in the camera's ACL. A granted screen is the
        -- other way round -- the ACL admits, the radius still gates the panel.
        if screen.placement.access ~= "public" and not hasGrant(camera, player) then
            return nil, "access_denied"
        end
        return "ok", nil
    end

    -- A presentation that cannot be drawn right now goes `unavailable`: the
    -- record is kept -- the caller still owns it and getScreen/getView still
    -- reports it -- while the client binding and the interest point are let go.
    -- It comes back as `pending` the moment every condition holds again.
    local function markUnavailable(record, reason)
        if record.state == "unavailable" then return false end
        record.state, record.reason = "unavailable", reason
        record.attempt, record.sentRevision, record.nextAttemptAt = nil, nil, 0
        return true
    end

    local function revive(record)
        if record.state ~= "unavailable" then return false end
        record.state, record.reason, record.nextAttemptAt = "pending", nil, 0
        return true
    end

    local function screenViewersPass(roster)
        for _, screen in next, S.screens, nil do
            local camera = S.cameras[screen.cameraId]
            if camera then
                -- Resolved once per screen per pass: a parent that cannot be
                -- found right now is one reason applied to every viewer, not a
                -- lookup per player.
                local pose = screenPose(screen)
                -- The live table, not a copy: the state machine writes into the
                -- viewer record it is looking at. Deleting the key only happens
                -- on detach, which is the one mutation `next` allows mid-walk.
                for player, viewer in next, screen.viewers, nil do
                    local verdict, reason = screenAdmission(screen, camera, player, roster[player], pose)
                    if verdict == nil then
                        detachViewer(screen, player, reason)
                    elseif verdict == "unavailable" then
                        if markUnavailable(viewer, reason) then
                            dismiss(player, screen.id)
                            emit("screenViewer", "state", screen,
                                { screenId = screen.id, cameraId = camera.id, playerId = player,
                                  state = "unavailable", reason = reason })
                        end
                    elseif revive(viewer) then
                        emit("screenViewer", "state", screen,
                            { screenId = screen.id, cameraId = camera.id, playerId = player,
                              state = "pending" })
                    end
                end
                for player, entry in next, roster, nil do
                    if screen.viewers[player] == nil then
                        local verdict = screenAdmission(screen, camera, player, entry, pose)
                        if verdict == "ok" then attachViewer(screen, player) end
                    end
                end
            end
        end
    end

    local function viewsPass(roster)
        local stale = {}
        for _, view in next, S.views, nil do
            local camera = S.cameras[view.cameraId]
            local entry = roster[view.player]
            local verdict, reason = "ok", nil
            if not camera then
                verdict, reason = nil, "camera_removed"
            elseif not entry then
                verdict, reason = "unavailable", "player_unavailable"
            elseif entry.bucket ~= camera.bucket then
                verdict, reason = nil, "bucket_changed"
            elseif not hasGrant(camera, view.player) then
                verdict, reason = nil, "access_revoked"
            elseif not camera.enabled then
                verdict, reason = "unavailable", "disabled"
            elseif entry.ready ~= true then
                verdict, reason = "unavailable", "player_not_ready"
            end
            if verdict == nil then
                stale[#stale + 1] = { view = view, reason = reason }
            elseif verdict == "unavailable" then
                if markUnavailable(view, reason) then
                    dismiss(view.player, view.id)
                    emit("view", "state", view,
                        { viewId = view.id, cameraId = view.cameraId, playerId = view.player,
                          state = "unavailable", reason = reason })
                end
            elseif revive(view) then
                emit("view", "state", view,
                    { viewId = view.id, cameraId = view.cameraId, playerId = view.player,
                      state = "pending" })
            end
        end
        for _, entry in ipairs(stale) do revokeView(entry.view, entry.reason) end
    end

    local function leasesPass(roster)
        local stale = {}
        for _, lease in next, S.leases, nil do
            local camera = S.cameras[lease.cameraId]
            local entry = roster[lease.player]
            local reason
            if not camera then
                reason = "camera_removed"
            elseif not entry then
                reason = "player_unavailable"
            elseif entry.bucket ~= camera.bucket then
                reason = "bucket_changed"
            elseif not camera.enabled then
                reason = "disabled"
            elseif entry.ready ~= true then
                reason = "player_not_ready"
            elseif not hasGrant(camera, lease.player) then
                reason = "access_revoked"
            end
            if reason then stale[#stale + 1] = { lease = lease, reason = reason } end
        end
        for _, entry in ipairs(stale) do releaseLease(entry.lease, entry.reason) end
    end

    local function samePoint(point, camera)
        return point.x == camera.position.x and point.y == camera.position.y
            and point.z == camera.position.z and point.radius == camera.range
            and point.bucket == camera.bucket
    end

    -- One interest point per (camera, viewer) pair, shared by every screen, HUD
    -- view and lease that names them: a player standing at three panels fed by
    -- one camera costs one replication point, not three.
    local function interestPass(effects)
        local desired = {}
        local function want(player, camera)
            local per = desired[player]
            if not per then
                per = {}
                desired[player] = per
            end
            per[camera.id] = camera
        end
        for _, camera in next, S.cameras, nil do
            if camera.enabled then
                local refs = S.cameraIndex[camera.id]
                if refs then
                    for _, screenId in ipairs(refs.screens) do
                        local screen = S.screens[screenId]
                        if screen then
                            for player, viewer in next, screen.viewers, nil do
                                if viewer.state ~= "unavailable" then want(player, camera) end
                            end
                        end
                    end
                    for _, viewId in ipairs(refs.views) do
                        local view = S.views[viewId]
                        if view and view.state ~= "unavailable" then want(view.player, camera) end
                    end
                    for _, leaseId in ipairs(refs.leases) do
                        local lease = S.leases[leaseId]
                        if lease then want(lease.player, camera) end
                    end
                end
            end
        end

        local removals = {}
        for player, per in next, S.interest, nil do
            for cameraId, entry in next, per, nil do
                local wanted = desired[player] and desired[player][cameraId]
                if not wanted and entry.state ~= "removing" then
                    entry.state = "removing"
                    removals[#removals + 1] = { player = player, cameraId = cameraId }
                end
            end
        end
        for _, removal in ipairs(removals) do
            effects[#effects + 1] = {
                op = "interest.remove", player = removal.player, cameraId = removal.cameraId,
            }
        end

        for player, per in next, desired, nil do
            for cameraId, camera in next, per, nil do
                local entry = interestEntry(player, cameraId)
                if entry == nil or (entry.state ~= "removing" and not samePoint(entry.point, camera)) then
                    local point = {
                        x = camera.position.x, y = camera.position.y, z = camera.position.z,
                        radius = camera.range, bucket = camera.bucket,
                    }
                    setInterest(player, cameraId, "pending", point)
                    effects[#effects + 1] = {
                        op = "interest.set", player = player, cameraId = cameraId,
                        position = copy(camera.position), radius = camera.range, bucket = camera.bucket,
                    }
                end
            end
        end
    end

    -- The revision of what a client is holding: the sink's own definition
    -- (rect, visibility, placement) and the camera it is showing. Both are
    -- monotone values from one counter, so the maximum changes whenever either
    -- changes and stays put when neither does.
    local function revisionOf(sink, camera)
        return math.max(sink.revision or 0, camera.revision or 0)
    end

    local function schedule(record, camera, revision, payload, now, effects)
        if record.state == "active" and record.sentRevision == revision then return end
        if now < (record.nextAttemptAt or 0) then return end
        local attempt = nextSerial()
        record.state, record.attempt, record.sentRevision = "pending", attempt, revision
        record.reason = nil
        record.nextAttemptAt = now + PRESENT_ACK_TIMEOUT_MS
        payload.attempt = attempt
        effects[#effects + 1] = { op = "present", player = record.player, presentation = payload }
    end

    -- Presentations: one native binding per screen or HUD view on the viewer's
    -- client, driven by the record's own revision and the camera's. An update
    -- that changes nothing is not resent; a change is a new attempt, and a late
    -- answer for the old one can no longer be mistaken for the new one.
    local function presentsPass(roster, now, effects)
        for _, view in next, S.views, nil do
            local camera = S.cameras[view.cameraId]
            if camera and view.state ~= "unavailable" and roster[view.player] then
                schedule(view, camera, revisionOf(view, camera), {
                    id = view.id, kind = "view", cameraId = camera.id,
                    camera = {
                        position = copy(camera.position), rotation = copy(camera.rotation),
                        fov = camera.fov, range = camera.range,
                    },
                    rect = copy(view.rect), visible = view.visible, surface = view.surface,
                }, now, effects)
            end
        end
        for _, screen in next, S.screens, nil do
            local camera = S.cameras[screen.cameraId]
            if camera and camera.enabled then
                for _, viewer in next, screen.viewers, nil do
                    if viewer.state ~= "unavailable" then
                        schedule(viewer, camera, revisionOf(screen, camera), {
                            id = screen.id, kind = "screen", cameraId = camera.id,
                            camera = {
                                position = copy(camera.position), rotation = copy(camera.rotation),
                                fov = camera.fov, range = camera.range,
                            },
                            placement = {
                                position = copy(screen.placement.position),
                                rotation = copy(screen.placement.rotation),
                                width = screen.placement.width, height = screen.placement.height,
                                model = screen.placement.model,
                                -- The parent travels with the local offset so the
                                -- client parents the panel natively and follows
                                -- it between sparse updates.
                                parent = screen.placement.parent and {
                                    type = screen.placement.parent.type,
                                    id = screen.placement.parent.id,
                                } or nil,
                            },
                        }, now, effects)
                    end
                end
            end
        end
    end

    -- Where a client's answer lands. The attempt id is the correlation: an
    -- answer for an attempt this record is no longer waiting on is stale
    -- traffic -- a late frame, a superseded retry -- and is dropped, never
    -- applied. Nothing a client says here can create, move or authorize a
    -- record; it can only report on a binding the server already asked for.
    function S.presentResult(player, id, attempt, ok, reason)
        if not validId(id) or not validId(attempt) then return false, "invalid_id" end
        local view = S.views[id]
        local record
        local screen
        if view and view.player == player then
            record = view
        else
            screen = S.screens[id]
            record = screen and screen.viewers[player] or nil
        end
        if not record then return false, "not_found" end
        if record.attempt ~= attempt then return false, "stale_attempt" end
        record.attempt = nil
        if ok == true then
            record.state, record.reason, record.nextAttemptAt = "active", nil, 0
        else
            record.state = "failed"
            record.reason = tostring(reason or "unknown")
            record.nextAttemptAt = (S.now or 0) + PRESENT_RETRY_MS
        end
        if view and record == view then
            emit("view", "state", view,
                { viewId = id, cameraId = view.cameraId, playerId = player,
                  state = record.state, reason = record.reason })
        elseif screen then
            emit("screenViewer", "state", screen,
                { screenId = id, cameraId = screen.cameraId, playerId = player,
                  state = record.state, reason = record.reason })
        end
        return true
    end

    -- The adapter's answer to an interest effect. A set that was refused drops
    -- the pair and takes its presentations down with it; a removal that failed
    -- leaves the point marked active so the next pass asks again rather than
    -- leaking a stream nobody wants.
    function S.interestResult(player, cameraId, op, ok, reason)
        if not validId(player) or not validId(cameraId) then return false, "invalid_id" end
        local entry = interestEntry(player, cameraId)
        if not entry then return false, "not_found" end
        if ok == true then
            if op == "set" then
                entry.state = "active"
            else
                setInterest(player, cameraId, nil)
            end
            return true
        end
        if op == "set" then
            setInterest(player, cameraId, nil)
            interestFailed(player, cameraId, tostring(reason or "interest_unavailable"))
        else
            entry.state = "active"
        end
        return true
    end

    function S.reconcile(params)
        if type(params) ~= "table" then params = {} end
        S.now = tonumber(params.now) or 0
        local roster = readRoster()
        local effects = {}

        S.tick()
        screenViewersPass(roster)
        viewsPass(roster)
        leasesPass(roster)
        interestPass(effects)
        for _, queued in ipairs(S.dismissals) do
            effects[#effects + 1] = { op = "dismiss", player = queued.player, id = queued.id }
        end
        S.dismissals = {}
        presentsPass(roster, S.now, effects)
        return effects
    end

    ----------------------------------------------------------------------
    -- Introspection for the adapter
    ----------------------------------------------------------------------

    -- Every interest point the adapter believes it holds, for diagnostics and
    -- for the adapter's own tests.
    function S.interests()
        local result = {}
        for player, per in next, S.interest, nil do
            for cameraId, entry in next, per, nil do
                result[#result + 1] = {
                    player = player, cameraId = cameraId, state = entry.state,
                    point = copy(entry.point),
                }
            end
        end
        table.sort(result, function(a, b)
            if a.player == b.player then return a.cameraId < b.cameraId end
            return a.player < b.player
        end)
        return result
    end

    -- Every presentation the adapter has told a client to draw, for a final
    -- dismissal when the provider stops.
    function S.presentations()
        local result = {}
        for id, view in next, S.views, nil do
            result[#result + 1] = { player = view.player, id = id }
        end
        for id, screen in next, S.screens, nil do
            for player in next, screen.viewers, nil do
                result[#result + 1] = { player = player, id = id }
            end
        end
        return result
    end

    return S
end
