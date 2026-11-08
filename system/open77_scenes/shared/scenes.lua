-- =============================================================================
-- open77_scenes -- shared/scenes.lua
-- =============================================================================
-- What a scene is, as data. Both halves load it (no setmetatable: the client
-- Lua sandbox has none).
--
-- A scene is one RP profile (a device the body is mounted into) played at a
-- pose as three phases on that one device:
--   enter  a clip that carries the body onto the furniture (sit down);
--   idle   one of several loops, held until the player gets up;
--   exit   a clip that carries it off again (get up).
-- The platform's RP animation service owns the playback: the server starts
-- `Open77.animations.sequenceAt(enter, idle[hold])`, every client presents it,
-- late joiners receive the current step. This file only says which clips and
-- where the player's own body waits while the presented body plays.
--
-- Coordinates are the anchor's frame: metres, +Y the way the posture faces,
-- yaw in degrees about +Z (counter-clockwise, the convention of
-- `Open77.animations.playAt`).
-- =============================================================================

Open77Scenes = Open77Scenes or {}
local S = Open77Scenes

S.VERSION = "0.1.0"
S.definitions = S.definitions or {}
S.furniture = S.furniture or {}

local function finite(value) return type(value) == "number" and value == value and value > -1e9 and value < 1e9 end

local function point(value, name)
    if type(value) ~= "table" or not finite(value.x) or not finite(value.y) then
        error(name .. " must be { x, y [, z, yaw] }", 3)
    end
    return { x = value.x, y = value.y, z = finite(value.z) and value.z or 0.0, yaw = finite(value.yaw) and value.yaw or 0.0 }
end

local function clip(value, name, timed)
    if type(value) ~= "table" or type(value.clip) ~= "string" or #value.clip == 0 or #value.clip > 160 then
        error(name .. ".clip must be a clip name", 3)
    end
    if timed and (math.type(value.durationMs) ~= "integer" or value.durationMs < 1000 or value.durationMs > 600000) then
        error(name .. ".durationMs must be the clip's measured length (1000-600000)", 3)
    end
    return { clip = value.clip, durationMs = value.durationMs, label = type(value.label) == "string" and value.label or nil }
end

--- Registers (or replaces) a scene. Raises on a malformed definition.
--- def = { profile, label, prompt, enter = { clip, durationMs }, idles = { { clip, label }, ... },
---         exit = { clip, durationMs }, stand = { x, y, yaw }, waitYaw?, arrivalRadius? }
function S.define(id, def)
    if type(id) ~= "string" or not id:match("^[a-z][a-z0-9_]*$") or #id > 32 then error("scene id must be [a-z][a-z0-9_]{0,31}", 2) end
    if type(def) ~= "table" or type(def.profile) ~= "string" then error("scene needs a profile", 2) end
    local idles = {}
    for index, idle in ipairs(type(def.idles) == "table" and def.idles or {}) do
        idles[index] = clip(idle, "idles[" .. index .. "]", false)
    end
    if #idles == 0 or #idles > 8 then error("a scene has 1-8 idles", 2) end
    local scene = {
        id = id, profile = def.profile,
        label = type(def.label) == "string" and def.label or id,
        prompt = type(def.prompt) == "string" and def.prompt or "Use",
        enter = def.enter ~= nil and clip(def.enter, "enter", true) or nil,
        exit = def.exit ~= nil and clip(def.exit, "exit", true) or nil,
        idles = idles,
        stand = def.stand ~= nil and point(def.stand, "stand") or nil,
        -- The heading of the player's own body while it waits (anchor frame): the platform's RP
        -- view hangs its camera behind that body, so it faces the furniture to frame the scene.
        -- The body turns to `stand.yaw` when the exit starts, while it is still hidden.
        waitYaw = finite(def.waitYaw) and def.waitYaw or nil,
        arrivalRadius = finite(def.arrivalRadius) and math.max(0.5, math.min(1.5, def.arrivalRadius)) or 0.5,
    }
    S.definitions[id] = scene
    return scene
end

--- Says how a scene sits on a kind of furniture: the anchor is the furniture's
--- own transform moved by `offset` (in the furniture's frame) and turned by `yaw`.
function S.defineFurniture(kind, def)
    if type(kind) ~= "string" or #kind == 0 or #kind > 64 then error("furniture kind must be a short string", 2) end
    if type(def) ~= "table" or type(def.scene) ~= "string" then error("furniture needs a scene", 2) end
    S.furniture[kind] = {
        scene = def.scene, label = type(def.label) == "string" and def.label or kind,
        offset = point(def.offset or { x = 0, y = 0 }, "offset"),
        yaw = finite(def.yaw) and def.yaw or 0.0,
    }
    return S.furniture[kind]
end

-- -----------------------------------------------------------------------------
-- Geometry
-- -----------------------------------------------------------------------------
function S.wrap(yaw)
    yaw = (yaw + 180.0) % 360.0
    if yaw < 0 then yaw = yaw + 360.0 end
    return yaw - 180.0
end

--- `frame` (x, y, z, yaw) carried by a local point { x, y, z, yaw }: world x/y/z/yaw.
function S.compose(frame, offset)
    local r = math.rad(frame.yaw or 0)
    local c, s = math.cos(r), math.sin(r)
    local x, y = offset.x or 0, offset.y or 0
    return {
        x = frame.x + x * c - y * s,
        y = frame.y + x * s + y * c,
        z = (frame.z or 0) + (offset.z or 0),
        yaw = S.wrap((frame.yaw or 0) + (offset.yaw or 0)),
    }
end

--- The scene anchor of a spot { kind, x, y, z, yaw } (nil when the kind is unknown).
function S.anchorOf(spot)
    local furniture = S.furniture[spot.kind]
    if furniture == nil then return nil end
    local placed = S.compose(spot, furniture.offset)
    placed.yaw = S.wrap((spot.yaw or 0) + furniture.yaw)
    return placed
end

function S.distance(a, b)
    local dx, dy, dz = a.x - b.x, a.y - b.y, (a.z or 0) - (b.z or 0)
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

-- -----------------------------------------------------------------------------
-- Shipped scenes
-- -----------------------------------------------------------------------------
-- The ripperdoc chair of the prologue (q001, Viktor's clinic), V's own clips
-- carried onto both NPC rigs by scripts/animations/build-scene-assets.py: sit
-- down (6.8 s), two seated loops, get up (3.867 s). The entry and the exit are
-- baked onto the anchor, so the device stays on the chair for every client.
-- `stand` is where the get-up ends (measured from its trajectory: 1.584 m in
-- front of the seat, facing away from it); the player's own body waits there
-- for the whole scene, so the presented body hands back to it in place.
S.define("ripperdoc", {
    profile = "ripperdoc",
    label = "Ripperdoc chair",
    prompt = "Lie down",
    enter = { clip = "cyberm__ripperdoc__enter", durationMs = 6800 },
    idles = {
        { clip = "cyberm__ripperdoc__idle", label = "Rest" },
        { clip = "cyberm__ripperdoc__idle_device", label = "Arm in the scanner" },
    },
    exit = { clip = "cyberm__ripperdoc__exit", durationMs = 3867 },
    stand = { x = -0.057, y = 1.584, yaw = 2.13 },
    waitYaw = -177.94, -- from the stand point towards the anchor
    -- The waiting body is never seen; only its heading frames the camera. Measured 2026-10-30: a
    -- relocation of 0.83 m to the stand point settled without moving the body (`travel settle
    -- settled ... actual` unchanged) and a 0.75 m radius ended the scene `anchor_unreached`.
    arrivalRadius = 1.5,
})

-- The surgical chairs of the world (scan of the 2.5 sectors, server/spots-generated.lua). The
-- spot is the seat mesh's placement; the chair's length runs along the seat's local X, headrest
-- towards +X, so the posture (facing +Y) is turned 90 degrees, and the anchor goes down to the floor
-- the base stands on. Measured from the mesh bounds and placements, checked in game:
-- docs/research/rp-scenes.md.
S.defineFurniture("surgical_chair_a", { scene = "ripperdoc", label = "ripperdoc chair", offset = { x = 0.07, y = 0, z = -0.43 }, yaw = 90 })
-- The mirrored chair keeps the same pivot heights and headrest side (mirrored across its Y).
S.defineFurniture("surgical_chair_a_mirrored", { scene = "ripperdoc", label = "ripperdoc chair", offset = { x = 0.07, y = 0, z = -0.43 }, yaw = 90 })
-- Chair b: the base stands 0.52 m under the seat's pivot, the headrest 0.74 m along +X.
S.defineFurniture("surgical_chair_b", { scene = "ripperdoc", label = "ripperdoc chair", offset = { x = 0.08, y = 0, z = -0.52 }, yaw = 90 })
